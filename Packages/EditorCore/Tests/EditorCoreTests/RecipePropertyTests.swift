import Foundation
import Testing
@testable import EditorCore

/// A small, seeded generator, so a failing case can be replayed from its seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds random recipes: random scalars (sometimes out of range), wheels, curves,
/// crops, masks and retouch spots.
struct RecipeGenerator {
    var rng: SplitMix64
    private var tick: Int64 = 0

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func stamp() -> HLCStamp {
        tick += 1
        return HLCStamp(millis: 1_760_000_000_000 + tick, counter: 0, node: "prop")
    }

    mutating func unit() -> Double { Double.random(in: 0...1, using: &rng) }
    mutating func coin(_ p: Double = 0.5) -> Bool { unit() < p }
    /// On the 1/10 000 grid that `NormalizedPoint` encodes to, so round trips are exact.
    mutating func point() -> NormalizedPoint {
        NormalizedPoint(x: (unit() * 10_000).rounded() / 10_000, y: (unit() * 10_000).rounded() / 10_000)
    }

    mutating func uuid() -> UUID {
        let a = rng.next(), b = rng.next()
        return UUID(uuid: withUnsafeBytes(of: (a, b)) { raw in
            (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])
        })
    }

    mutating func recipe() -> Recipe {
        var recipe = Recipe()
        for spec in ParamCatalog.all where coin(0.3) {
            switch spec.kind {
            case .scalar(let range, _):
                // A tenth of the values land outside the range, to exercise clamping.
                let span = range.upperBound - range.lowerBound
                let value = coin(0.1) ? range.upperBound + span * unit() : range.lowerBound + span * unit()
                recipe.setScalar(spec.key, value, at: stamp())
            case .point:
                recipe.set(spec.key, .point(x: unit() * 2 - 1, y: unit() * 2 - 1), at: stamp())
            case .curve:
                recipe.set(spec.key, .curve([CurvePoint(x: 0, y: unit() * 0.2), CurvePoint(x: 0.5, y: unit()), CurvePoint(x: 1, y: 0.8 + unit() * 0.2)]), at: stamp())
            case .lut:
                recipe.set(spec.key, .lut(LUTRef(hash: "h\(rng.next() % 100)", name: "LUT"), amount: unit()), at: stamp())
            case .crop:
                let w = 0.2 + unit() * 0.8, h = 0.2 + unit() * 0.8
                recipe.set(spec.key, .crop(CropGeometry(
                    rect: NormalizedRect(x: unit() * (1 - w), y: unit() * (1 - h), width: w, height: h),
                    angle: unit() * 20 - 10, aspect: coin() ? AspectRatio(3, 2) : nil
                )), at: stamp())
            case .color:
                recipe.set(spec.key, .color(coin() ? .white : SRGBColor(red: 0.5, green: 0.25, blue: 0)), at: stamp())
            case .aspect:
                recipe.set(spec.key, .aspect(coin() ? AspectRatio(1, 1) : AspectRatio(4, 5)), at: stamp())
            case .watermark:
                let positions = WatermarkPosition.allCases
                recipe.set(spec.key, .watermark(Watermark(text: "© Test \(rng.next() % 100)", position: positions[Int(rng.next() % UInt64(positions.count))])), at: stamp())
            case .mask, .retouch:
                break
            }
        }
        for _ in 0..<Int(rng.next() % 3) {
            let shapes: [MaskShape] = [
                .linear(start: point(), end: point()),
                .radial(center: point(), radiusX: unit(), radiusY: unit(), angle: unit() * 360, feather: unit()),
                .brush(strokes: [BrushStroke(points: [point(), point()], radius: unit() * 0.1)]),
                .luminance(low: unit() * 0.5, high: 0.5 + unit() * 0.5, feather: unit()),
                .ai(kind: AIMaskKind.allCases[Int(rng.next() % UInt64(AIMaskKind.allCases.count))]),
            ]
            let shape = shapes[Int(rng.next() % UInt64(shapes.count))]
            recipe.setMask(MaskLayer(
                id: uuid(), name: "Mask", order: recipe.nextMaskOrder,
                components: [MaskComponent(id: uuid(), shape: shape)],
                adjustments: [.exposure: unit() * 2 - 1], amount: unit()
            ), at: stamp())
        }
        for _ in 0..<Int(rng.next() % 3) {
            let kind = RetouchSpot.Kind.allCases[Int(rng.next() % 3)]
            recipe.setRetouch(RetouchSpot(
                id: uuid(), order: recipe.nextRetouchOrder, kind: kind,
                strokes: [BrushStroke(points: [point()], radius: 0.02)],
                sourceOffset: kind.needsSource ? NormalizedPoint(x: 0.1, y: 0.1) : nil
            ), at: stamp())
        }
        return recipe
    }

    mutating func groups() -> Set<PasteGroup> {
        Set(PasteGroup.allCases.filter { _ in coin() })
    }
}

/// Invariants that should hold for any recipe, checked on a few hundred random ones.
/// A failure names its seed; reproduce it with `RecipeGenerator(seed:)`.
@Suite struct RecipePropertyTests {
    static let seeds: [UInt64] = Array(1...200)

    private func catalogKeys(in groups: Set<PasteGroup>) -> Set<ParamKey> {
        Set(ParamCatalog.all.filter { groups.contains($0.group) }.map(\.key))
    }

    @Test(arguments: [0, 1, 2, 3])
    func codecRoundTripsRandomRecipes(shard: Int) throws {
        for seed in Self.seeds where Int(seed) % 4 == shard {
            var generator = RecipeGenerator(seed: seed)
            let recipe = generator.recipe()
            let decoded = try RecipeCodec.decode(RecipeCodec.encode(recipe))
            #expect(decoded == recipe, "seed \(seed)")
        }
    }

    @Test func scalarsStayInRange() {
        for seed in Self.seeds {
            var generator = RecipeGenerator(seed: seed)
            let recipe = generator.recipe()
            for spec in ParamCatalog.all {
                guard let range = spec.range, let value = recipe.scalar(spec.key) else { continue }
                #expect(range.contains(value), "seed \(seed): \(spec.key) = \(value) outside \(range)")
            }
        }
    }

    /// Pasting never changes a parameter outside the chosen groups.
    @Test(arguments: PasteMode.allCases)
    func pasteOnlyTouchesSelectedGroups(mode: PasteMode) {
        for seed in Self.seeds {
            var generator = RecipeGenerator(seed: seed)
            let source = generator.recipe(), target = generator.recipe(), groups = generator.groups()
            let clip = RecipeClip(recipe: source, sourceName: "src", sourceDefaults: .generic)
            let result = target.pasting(clip, groups: groups, mode: mode, targetDefaults: .generic, stamp: generator.stamp())
            let selected = catalogKeys(in: groups)
            for spec in ParamCatalog.all where !selected.contains(spec.key) {
                #expect(result[spec.key] == target[spec.key], "seed \(seed) \(mode): \(spec.key) changed outside \(groups)")
            }
            if !groups.contains(.masks) { #expect(result.masks == target.masks, "seed \(seed): masks changed") }
            if !groups.contains(.retouch) { #expect(result.retouches == target.retouches, "seed \(seed): retouches changed") }
        }
    }

    /// Set mode with every group makes the target match the source.
    @Test func setModeWithEverythingCopiesTheSource() {
        for seed in Self.seeds {
            var generator = RecipeGenerator(seed: seed)
            let source = generator.recipe(), target = generator.recipe()
            let clip = RecipeClip(recipe: source, sourceName: "src", sourceDefaults: .generic)
            let result = target.pasting(clip, groups: Set(PasteGroup.allCases), mode: .set, targetDefaults: .generic, stamp: generator.stamp())
            #expect(result.params == source.params, "seed \(seed)")
        }
    }

    /// Pasting the same clip twice in set mode is the same as pasting it once.
    @Test func setModeIsIdempotent() {
        for seed in Self.seeds {
            var generator = RecipeGenerator(seed: seed)
            let source = generator.recipe(), target = generator.recipe(), groups = generator.groups()
            let clip = RecipeClip(recipe: source, sourceName: "src", sourceDefaults: .generic)
            let once = target.pasting(clip, groups: groups, mode: .set, targetDefaults: .generic, stamp: generator.stamp())
            let twice = once.pasting(clip, groups: groups, mode: .set, targetDefaults: .generic, stamp: generator.stamp())
            #expect(once.params == twice.params, "seed \(seed)")
        }
    }

    /// Adjust mode with an unedited source changes nothing but masks and retouches.
    @Test func adjustingByNothingIsANoOp() {
        for seed in Self.seeds {
            var generator = RecipeGenerator(seed: seed)
            let target = generator.recipe()
            let clip = RecipeClip(recipe: Recipe(), sourceName: "src", sourceDefaults: .generic)
            let result = target.pasting(clip, groups: Set(PasteGroup.allCases), mode: .adjust, targetDefaults: .generic, stamp: generator.stamp())
            #expect(result.params == target.params, "seed \(seed)")
        }
    }

    /// Paste groups split the catalog: every parameter belongs to exactly one group,
    /// and `params(in:)` with every group returns every catalog parameter that's set.
    @Test func pasteGroupsPartitionTheCatalog() {
        for seed in Self.seeds.prefix(50) {
            var generator = RecipeGenerator(seed: seed)
            let recipe = generator.recipe()
            let all = recipe.params(in: Set(PasteGroup.allCases))
            #expect(all.count == recipe.params.count, "seed \(seed): some parameters belong to no paste group")
            var union: [ParamKey: ParamValue] = [:]
            for group in PasteGroup.allCases {
                for (key, value) in recipe.params(in: [group]) {
                    #expect(union[key] == nil, "seed \(seed): \(key) is in two groups")
                    union[key] = value
                }
            }
            #expect(union == all)
        }
    }

    /// Resets keep their stamps: a recipe's stamps are never fewer than its values.
    @Test func everyValueHasAStamp() {
        for seed in Self.seeds {
            var generator = RecipeGenerator(seed: seed)
            var recipe = generator.recipe()
            #expect(Set(recipe.params.keys).isSubset(of: Set(recipe.stamps.keys)), "seed \(seed)")
            recipe.resetAll(at: generator.stamp())
            #expect(recipe.isIdentity, "seed \(seed): resetAll left values")
            #expect(!recipe.stamps.isEmpty || recipe == Recipe(), "seed \(seed): reset dropped stamps")
        }
    }
}
