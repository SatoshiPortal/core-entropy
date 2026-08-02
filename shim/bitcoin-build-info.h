// Not a Bitcoin Core file. Core generates this from
// cmake/script/GenerateBuildInfo.cmake, which emits BUILD_GIT_TAG or
// BUILD_GIT_COMMIT depending on the checkout state, or nothing at all.
//
// Emitting nothing is a state Core handles: clientversion.cpp falls back to
// BUILD_DESC = "v" CLIENT_VERSION_STRING. Deliberately left empty so this
// library's build does not depend on git metadata, which would break
// reproducible builds.
