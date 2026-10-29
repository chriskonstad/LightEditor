import Foundation

/// DPM-Solver++ (2M) for Stable Diffusion 1.5's noise schedule, the sampler
/// diffusers uses for `DPMSolverMultistepScheduler`. Data prediction, second
/// order, first order on the first step.
///
/// Works on flat Float arrays (latents), so it's testable without a model.
public struct DiffusionSampler: Sendable {
    /// ᾱ for each of the 1000 training timesteps (scaled linear betas, 0.00085…0.012).
    static let alphasCumprod: [Double] = {
        let start = 0.00085.squareRoot(), end = 0.012.squareRoot()
        var product = 1.0
        return (0..<1000).map { i in
            let beta = pow(start + (end - start) * Double(i) / 999, 2)
            product *= 1 - beta
            return product
        }
    }()

    /// The timesteps to visit, from noisiest. `strength` < 1 starts partway,
    /// keeping the initial image's structure (img2img).
    public let timesteps: [Int]

    public init(steps: Int, strength: Double = 1) {
        let all = (0..<steps).map { i in Int((999 * (1 - Double(i) / Double(steps))).rounded()) }
        let used = min(max(Int((Double(steps) * strength).rounded()), 1), steps)
        timesteps = Array(all.suffix(used))
    }

    static func alpha(_ t: Int) -> Double { alphasCumprod[t].squareRoot() }
    static func sigma(_ t: Int) -> Double { (1 - alphasCumprod[t]).squareRoot() }

    /// Noises a clean latent to the first timestep: √ᾱ·x0 + √(1−ᾱ)·ε.
    public func noised(_ clean: [Float], noise: [Float]) -> [Float] {
        let t = timesteps[0]
        let a = Float(Self.alpha(t)), s = Float(Self.sigma(t))
        return zip(clean, noise).map { a * $0 + s * $1 }
    }

    /// Runs the loop. `predictNoise(x, t)` returns ε for the latent at timestep t
    /// (already combining guidance).
    public func sample(from start: [Float], predictNoise: (_ x: [Float], _ t: Int, _ step: Int) async throws -> [Float]) async throws -> [Float] {
        var x = start
        var previous: (x0: [Float], lambda: Double)?
        for (step, t) in timesteps.enumerated() {
            try Task.checkCancellation()
            let eps = try await predictNoise(x, t, step)
            let alphaS = Self.alpha(t), sigmaS = Self.sigma(t)
            // The model's guess at the clean latent.
            let x0 = zip(x, eps).map { Float((Double($0) - sigmaS * Double($1)) / alphaS) }
            let lambdaS = log(alphaS) - log(sigmaS)
            let isLast = step == timesteps.count - 1
            if isLast {
                // To t = 0 (σ = 0): the clean estimate itself.
                x = x0
                break
            }
            let next = timesteps[step + 1]
            let alphaT = Self.alpha(next), sigmaT = Self.sigma(next)
            let lambdaT = log(alphaT) - log(sigmaT)
            let h = lambdaT - lambdaS
            let ratio = Float(sigmaT / sigmaS)
            let coefficient = Float(-alphaT * (exp(-h) - 1))
            if let previous {
                // Second order: D = x0 + (x0 − x0_prev) / (2r).
                let r = (lambdaS - previous.lambda) / h
                let k = Float(0.5 / r)
                x = (0..<x.count).map { i in
                    let d = x0[i] + k * (x0[i] - previous.x0[i])
                    return ratio * x[i] + coefficient * d
                }
            } else {
                x = (0..<x.count).map { ratio * x[$0] + coefficient * x0[$0] }
            }
            previous = (x0, lambdaS)
        }
        return x
    }
}

/// Seeded Gaussian noise, the same on every device for a given seed.
public struct SeededNoise: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// SplitMix64.
    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }

    /// Box–Muller.
    public mutating func gaussian(count: Int) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(count)
        while values.count < count {
            let u = uniform(), v = uniform()
            let radius = (-2 * log(u)).squareRoot()
            values.append(Float(radius * cos(2 * .pi * v)))
            if values.count < count { values.append(Float(radius * sin(2 * .pi * v))) }
        }
        return values
    }
}
