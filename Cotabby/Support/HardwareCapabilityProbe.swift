import Foundation

/// File overview:
/// Reads the host's installed memory and CPU architecture so onboarding can recommend and gate
/// model templates. Kept as a tiny seam (rather than reading `ProcessInfo` inline in the view) so
/// `OnboardingTemplateRecommender` stays a pure function of a `HardwareCapability` value and can be
/// exercised with synthetic hardware in tests.
enum HardwareCapabilityProbe {
    static func current() -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            isAppleSilicon: isAppleSilicon
        )
    }

    /// Compile-time architecture is sufficient here: the app ships a single universal binary and we
    /// only need to distinguish Apple Silicon from Intel for model-fit messaging. A Rosetta-translated
    /// run reporting `x86_64` is an acceptable, conservative misread for that purpose.
    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
