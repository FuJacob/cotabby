import Foundation

/// File overview:
/// Reads the host's installed memory so onboarding can recommend and gate
/// model templates. Kept as a tiny seam (rather than reading `ProcessInfo` inline in the view) so
/// `OnboardingTemplateRecommender` stays a pure function of a `HardwareCapability` value and can be
/// exercised with synthetic hardware in tests.
enum HardwareCapabilityProbe {
    static func current() -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}
