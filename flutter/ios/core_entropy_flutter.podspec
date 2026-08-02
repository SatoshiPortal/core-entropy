Pod::Spec.new do |s|
  s.name             = 'core_entropy_flutter'
  s.version          = '0.1.0'
  s.summary          = "Bitcoin Core's RNG for Flutter on iOS."
  s.description      = <<-DESC
Vendored, byte-identical Bitcoin Core v29.0 RNG. Uses getentropy(2), supplied
over CCRandomGenerateBytes because iOS exports no getentropy. No /dev/urandom
fallback: if the OS entropy source fails, the process aborts.
                       DESC
  s.homepage         = 'https://github.com/SatoshiPortal/core-entropy'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Satoshi Portal' => 'hello@bullbitcoin.com' }
  s.source           = { :path => '.' }

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Compiled from the same sources every other target uses. `core/` is
  # upstream Bitcoin Core; `shim/` and `src/` are this project's only code.
  # Vendors the artifact produced and checked by scripts/build_ios.sh, which
  # asserts that the binary contains no /dev/urandom path and does reference
  # CCRandomGenerateBytes. Recompiling the sources here instead would produce a
  # second binary that never passed those checks.
  unless File.directory?(File.join(__dir__, 'CoreEntropy.xcframework'))
    Dir.chdir(File.join(__dir__, '..', '..')) do
      raise 'core-entropy: scripts/build_ios.sh failed' unless
        system('./scripts/build_ios.sh')
    end
  end

  # No Objective-C or Swift source. The framework is dynamic, so its symbols
  # survive independently of the host app's dead-stripping and Dart resolves
  # them at runtime with DynamicLibrary.open — nothing needs to reference them
  # from native code to keep them alive.
  s.vendored_frameworks = 'CoreEntropy.xcframework'
  s.preserve_paths      = 'CoreEntropy.xcframework'

  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
        'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES',
    # Keep the C ABI symbols; Dart looks them up in the process image.
    'DEAD_CODE_STRIPPING' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
