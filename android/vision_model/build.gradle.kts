plugins {
    id("com.android.asset-pack")
}

// The vision model ships with the app instead of being downloaded: install-time
// delivery means the weights are on the phone before the app first opens, which
// is what makes this feel identical to the iPhone build.
assetPack {
    packName.set("vision_model")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}
