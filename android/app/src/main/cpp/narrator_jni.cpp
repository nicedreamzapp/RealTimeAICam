// JNI bridge to llama.cpp + mtmd so the Android app can run the same vision
// narrator the iPhone runs. One image in, one spoken sentence out, on device.
#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>

#include "llama.h"
#include "ggml-backend.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "Narrator", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Narrator", __VA_ARGS__)

namespace {

struct narrator {
    llama_model   * model  = nullptr;
    llama_context * lctx   = nullptr;
    mtmd_context  * mctx   = nullptr;
    const llama_vocab * vocab = nullptr;
    int n_threads = 4;
};

std::string jstr(JNIEnv * env, jstring s) {
    if (s == nullptr) return {};
    const char * c = env->GetStringUTFChars(s, nullptr);
    std::string out = c ? c : "";
    env->ReleaseStringUTFChars(s, c);
    return out;
}

// Build the prompt with the model's own chat template so the fine-tune sees
// exactly the format it was trained on.
std::string apply_template(const llama_model * model,
                           const std::string & system,
                           const std::string & user) {
    const char * tmpl = llama_model_chat_template(model, nullptr);
    llama_chat_message msgs[2] = {
        {"system", system.c_str()},
        {"user",   user.c_str()},
    };
    std::vector<char> buf(system.size() + user.size() + 2048);
    int32_t n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t) buf.size());
    if (n > (int32_t) buf.size()) {
        buf.resize(n + 1);
        n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t) buf.size());
    }
    if (n < 0) {           // no template in the gguf: fall back to plain text
        return system + "\n\n" + user;
    }
    return std::string(buf.data(), n);
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_nativeInit(
        JNIEnv * env, jobject, jstring jmodel, jstring jmmproj, jint nThreads, jboolean useGpu) {
    const std::string model_path  = jstr(env, jmodel);
    const std::string mmproj_path = jstr(env, jmmproj);

    // llama.cpp and ggml talk to stderr, which Android throws away. Route
    // them into logcat so a failed load says why.
    llama_log_set([](ggml_log_level level, const char * text, void *) {
        int prio = level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR
                 : level == GGML_LOG_LEVEL_WARN  ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
        __android_log_write(prio, "llama", text);
    }, nullptr);
    llama_backend_init();
    LOGI("caller asked for %s", useGpu ? "GPU" : "CPU");

    // Vulkan is linked in; whether a usable GPU showed up is decided here at
    // runtime. No device (or the caller said no) means everything stays on
    // the CPU exactly as before.
    // A GPU is only used if it actually initialises. Some phone drivers
    // (PowerVR GE8320: no 16-bit storage buffers) make ggml throw the moment
    // the device is touched, and llama would then refuse to load the model
    // even for a CPU run — so the device list handed to llama is built here,
    // explicitly, and the GPU is probed first.
    std::vector<ggml_backend_dev_t> devices;
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        LOGI("backend device %zu: %s (%s)", i, ggml_backend_dev_name(dev), ggml_backend_dev_description(dev));
        if (!useGpu || ggml_backend_dev_type(dev) != GGML_BACKEND_DEVICE_TYPE_GPU) continue;
        bool ok = false;
        try {
            ggml_backend_t probe = ggml_backend_dev_init(dev, nullptr);
            if (probe) { ggml_backend_free(probe); ok = true; }
        } catch (const std::exception & e) {
            LOGE("GPU %s refused: %s", ggml_backend_dev_name(dev), e.what());
        } catch (...) {
            LOGE("GPU %s refused", ggml_backend_dev_name(dev));
        }
        if (ok) devices.push_back(dev);
    }
    const bool gpu = !devices.empty();
    devices.push_back(nullptr);  // llama wants a null-terminated list
    LOGI("running on %s", gpu ? ggml_backend_dev_description(devices[0]) : "CPU");

    llama_model_params mparams = llama_model_default_params();
    mparams.devices      = devices.data();
    mparams.n_gpu_layers = gpu ? 99 : 0;
    llama_model * model = llama_model_load_from_file(model_path.c_str(), mparams);
    if (!model) { LOGE("failed to load %s", model_path.c_str()); return 0; }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx     = 4096;
    cparams.n_batch   = 2048;
    cparams.n_ubatch  = 512;
    cparams.n_threads = nThreads;
    cparams.n_threads_batch = nThreads;
    llama_context * lctx = llama_init_from_model(model, cparams);
    if (!lctx) { LOGE("failed to create context"); llama_model_free(model); return 0; }

    mtmd_context_params vparams = mtmd_context_params_default();
    vparams.use_gpu        = gpu;
    vparams.print_timings  = false;
    vparams.n_threads      = nThreads;
    vparams.warmup         = false;
    mtmd_context * mctx = mtmd_init_from_file(mmproj_path.c_str(), model, vparams);
    if (!mctx) { LOGE("failed to load mmproj %s", mmproj_path.c_str());
                 llama_free(lctx); llama_model_free(model); return 0; }

    auto * n = new narrator();
    n->model = model; n->lctx = lctx; n->mctx = mctx;
    n->vocab = llama_model_get_vocab(model);
    n->n_threads = nThreads;
    LOGI("narrator ready");
    return reinterpret_cast<jlong>(n);
}

JNIEXPORT jstring JNICALL
Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_nativeDescribe(
        JNIEnv * env, jobject, jlong handle, jstring jimage,
        jstring jsystem, jstring jquestion, jint maxTokens) {
    auto * n = reinterpret_cast<narrator *>(handle);
    if (!n) return env->NewStringUTF("");

    const std::string image_path = jstr(env, jimage);
    const std::string system     = jstr(env, jsystem);
    const std::string question   = jstr(env, jquestion);

    // start from a clean slate for every photo
    llama_memory_clear(llama_get_memory(n->lctx), true);

    auto wrapper = mtmd_helper_bitmap_init_from_file(
            n->mctx, image_path.c_str(), false, mtmd_helper_init_opt_default());
    if (!wrapper.bitmap) { LOGE("could not read %s", image_path.c_str());
                           return env->NewStringUTF(""); }

    const std::string user   = std::string(mtmd_default_marker()) + "\n" + question;
    const std::string prompt = apply_template(n->model, system, user);

    mtmd_input_text text{};
    text.text          = prompt.c_str();
    text.text_len      = prompt.size();
    text.add_special   = true;
    text.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    const mtmd_bitmap * bitmaps[1] = { wrapper.bitmap };
    if (mtmd_tokenize(n->mctx, chunks, &text, bitmaps, 1) != 0) {
        LOGE("tokenize failed");
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(wrapper.bitmap);
        return env->NewStringUTF("");
    }

    llama_pos n_past = 0;
    int32_t rc = mtmd_helper_eval_chunks(n->mctx, n->lctx, chunks, 0, 0,
                                         2048, /* logits_last */ true, &n_past);
    mtmd_input_chunks_free(chunks);
    mtmd_bitmap_free(wrapper.bitmap);
    if (rc != 0) { LOGE("eval failed (%d)", rc); return env->NewStringUTF(""); }

    // Greedy: the model was trained to give one settled answer, not to be creative.
    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    std::string out;
    llama_batch batch = llama_batch_init(1, 0, 1);
    for (int i = 0; i < maxTokens; ++i) {
        llama_token tok = llama_sampler_sample(smpl, n->lctx, -1);
        if (llama_vocab_is_eog(n->vocab, tok)) break;

        char piece[256];
        int len = llama_token_to_piece(n->vocab, tok, piece, sizeof(piece), 0, true);
        if (len > 0) out.append(piece, len);

        batch.n_tokens  = 1;
        batch.token[0]  = tok;
        batch.pos[0]    = n_past++;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = true;
        if (llama_decode(n->lctx, batch)) { LOGE("decode failed"); break; }
    }
    llama_batch_free(batch);
    llama_sampler_free(smpl);

    // Some Qwen builds emit an empty reasoning block first; speak only the answer.
    const size_t end_think = out.rfind("</think>");
    if (end_think != std::string::npos) out = out.substr(end_think + 8);
    while (!out.empty() && (out.front() == '\n' || out.front() == ' ')) out.erase(out.begin());
    while (!out.empty() && (out.back()  == '\n' || out.back()  == ' ')) out.pop_back();

    return env->NewStringUTF(out.c_str());
}

JNIEXPORT void JNICALL
Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_nativeFree(
        JNIEnv *, jobject, jlong handle) {
    auto * n = reinterpret_cast<narrator *>(handle);
    if (!n) return;
    if (n->mctx)  mtmd_free(n->mctx);
    if (n->lctx)  llama_free(n->lctx);
    if (n->model) llama_model_free(n->model);
    delete n;
}

} // extern "C"
