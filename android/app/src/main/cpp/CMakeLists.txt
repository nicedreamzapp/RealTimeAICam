cmake_minimum_required(VERSION 3.22)
project(narrator)

set(CMAKE_CXX_STANDARD 17)

# The narrator only ships on 64-bit ARM. The model is 736 MB; a 32-bit phone
# cannot map it, and llama.cpp's fp16 kernels do not build for armeabi-v7a.
# On other ABIs we emit a stub so the APK still links and the feature hides itself.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(PREBUILT ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
    foreach(lib llama mtmd ggml ggml-base ggml-cpu)
        add_library(${lib} SHARED IMPORTED)
        set_target_properties(${lib} PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib${lib}.so)
    endforeach()

    add_library(narrator SHARED narrator_jni.cpp)
    target_include_directories(narrator PRIVATE ${CMAKE_SOURCE_DIR}/include)
    target_link_libraries(narrator llama mtmd ggml ggml-base ggml-cpu log android)
else()
    add_library(narrator SHARED narrator_stub.cpp)
    target_link_libraries(narrator log)
endif()
