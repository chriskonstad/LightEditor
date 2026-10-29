import CoreImage
import EditorCore
import Foundation

/// Mask editing: creating layers and components, painting, tapping and AI.
extension EditorModel {
    var masks: [MaskLayer] { recipe.masks }

    var selectedMask: MaskLayer? {
        guard let selectedMaskID else { return nil }
        return masks.first { $0.id == selectedMaskID }
    }

    var selectedComponent: MaskComponent? {
        guard let mask = selectedMask else { return nil }
        return mask.components.first { $0.id == selectedComponentID } ?? mask.components.last
    }

    // MARK: Layers

    /// Creates a mask from one shape and selects it.
    func addMask(_ shape: MaskShape) {
        let name = uniqueName(shape.displayName)
        let component = MaskComponent(shape: shape)
        let layer = MaskLayer(name: name, order: recipe.nextMaskOrder, components: [component])
        updateRecipe("Add \(name) mask") { recipe, stamp in recipe.setMask(layer, at: stamp) }
        selectedMaskID = layer.id
        selectedComponentID = component.id
        tab = .masks
        computeAIIfNeeded(shape)
    }

    func addComponent(_ shape: MaskShape, operation: MaskComponent.Operation) {
        guard var layer = selectedMask else { return addMask(shape) }
        let component = MaskComponent(operation: operation, shape: shape)
        layer.components.append(component)
        updateRecipe("\(operation.displayName) \(shape.displayName)") { recipe, stamp in recipe.setMask(layer, at: stamp) }
        selectedComponentID = component.id
        computeAIIfNeeded(shape)
    }

    /// Edits the selected layer. Pass a label to make it a history step.
    func editSelectedMask(_ label: String? = nil, _ change: (inout MaskLayer) -> Void) {
        guard var layer = selectedMask else { return }
        change(&layer)
        updateRecipe(label) { recipe, stamp in recipe.setMask(layer, at: stamp) }
    }

    /// Edits the selected component's shape.
    func editSelectedShape(_ label: String? = nil, _ change: (inout MaskShape) -> Void) {
        guard let id = selectedComponent?.id else { return }
        editSelectedMask(label) { layer in
            guard let index = layer.components.firstIndex(where: { $0.id == id }) else { return }
            change(&layer.components[index].shape)
        }
    }

    func editComponent(_ id: UUID, label: String, _ change: (inout MaskComponent) -> Void) {
        editSelectedMask(label) { layer in
            guard let index = layer.components.firstIndex(where: { $0.id == id }) else { return }
            change(&layer.components[index])
        }
    }

    func deleteComponent(_ id: UUID) {
        guard let layer = selectedMask else { return }
        if layer.components.count <= 1 { return deleteMask(layer.id) }
        editSelectedMask("Remove part of \(layer.name)") { $0.components.removeAll { $0.id == id } }
        if selectedComponentID == id { selectedComponentID = selectedMask?.components.last?.id }
    }

    func deleteMask(_ id: UUID) {
        let name = masks.first { $0.id == id }?.name ?? "mask"
        updateRecipe("Delete \(name)") { recipe, stamp in recipe.removeMask(id, at: stamp) }
        if selectedMaskID == id {
            selectedMaskID = masks.last?.id
            selectedComponentID = masks.last?.components.last?.id
        }
    }

    func duplicateMask(_ id: UUID) {
        guard var copy = masks.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name = uniqueName(copy.name)
        copy.order = recipe.nextMaskOrder
        copy.components = copy.components.map { var c = $0; c.id = UUID(); return c }
        let layer = copy
        updateRecipe("Duplicate \(layer.name)") { recipe, stamp in recipe.setMask(layer, at: stamp) }
        selectedMaskID = layer.id
        selectedComponentID = layer.components.last?.id
    }

    func selectMask(_ id: UUID?) {
        selectedMaskID = id
        selectedComponentID = masks.first { $0.id == id }?.components.last?.id
    }

    func setMaskEnabled(_ id: UUID, _ enabled: Bool) {
        guard var layer = masks.first(where: { $0.id == id }) else { return }
        layer.isEnabled = enabled
        let updated = layer
        updateRecipe(enabled ? "Show \(layer.name)" : "Hide \(layer.name)") { recipe, stamp in recipe.setMask(updated, at: stamp) }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(masks.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: Local adjustments

    func maskValue(_ key: ParamKey) -> Double { selectedMask?.adjustments[key] ?? 0 }

    func setMaskValueLive(_ key: ParamKey, _ value: Double) {
        editSelectedMask { layer in
            let range = MaskLayer.range(for: key)
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            layer.adjustments[key] = abs(clamped) < 1e-9 ? nil : clamped
        }
    }

    func commitMaskValue(_ key: ParamKey) {
        guard let layer = selectedMask else { return }
        let label = key == .localTemperature ? "Temperature" : key == .localTint ? "Tint" : ParamCatalog.spec(for: key)?.label ?? key.rawValue
        pushHistory(label: "\(layer.name): \(label)")
    }

    // MARK: Painting and tapping (normalized points on the original image)

    func beginStroke(at point: NormalizedPoint) {
        paintingStroke = BrushStroke(points: [point], radius: brushSize, feather: brushFeather, flow: brushFlow, erase: brushErase)
        applyPaintingStroke()
    }

    func extendStroke(to point: NormalizedPoint) {
        guard var stroke = paintingStroke else { return }
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < stroke.radius * 0.1 { return }
        stroke.points.append(point)
        paintingStroke = stroke
        applyPaintingStroke()
    }

    func endStroke() {
        guard let stroke = paintingStroke else { return }
        paintingStroke = nil
        let simplified = stroke.simplified()
        editSelectedShape(stroke.erase ? "Erase" : "Brush") { shape in
            guard case .brush(var strokes) = shape else { return }
            // Replace the live stroke (last) with its simplified version.
            if !strokes.isEmpty { strokes.removeLast() }
            strokes.append(simplified)
            shape = .brush(strokes: strokes)
        }
    }

    /// Puts the in-progress stroke into the recipe so it renders live.
    private func applyPaintingStroke() {
        guard let stroke = paintingStroke else { return }
        editSelectedShape { shape in
            guard case .brush(var strokes) = shape else { return }
            if let last = strokes.last, last.points.first == stroke.points.first, last.erase == stroke.erase, last.radius == stroke.radius {
                strokes[strokes.count - 1] = stroke
            } else {
                strokes.append(stroke)
            }
            shape = .brush(strokes: strokes)
        }
    }

    /// A tap on the photo while an object or color component is selected.
    func tapForMask(at point: NormalizedPoint) {
        guard let component = selectedComponent else { return }
        switch component.shape {
        case .object(let seeds):
            let shape = MaskShape.object(seeds: seeds + [point])
            editSelectedShape("Add to selection") { $0 = shape }
            computeAIIfNeeded(shape)
        case .color(_, _, _, let range):
            guard let lab = sampleColor(at: point) else { return }
            editSelectedShape("Pick color") { $0 = .color(l: lab.L, a: lab.a, b: lab.b, range: range) }
        default:
            break
        }
    }

    /// The color the mask stage sees at a point: the graded image before masks.
    func sampleColor(at point: NormalizedPoint) -> (L: Double, a: Double, b: Double)? {
        guard let decoded = base else { return nil }
        var withoutMasks = recipe
        for layer in withoutMasks.masks { withoutMasks.removeMask(layer.id, at: HLCStamp(millis: 0, node: "sample")) }
        let image = GradeGraph.apply(withoutMasks, to: decoded.image, inputs: GradeInputs(defaults: defaults, luts: app.lutStore, applyGeometry: false))
        let extent = image.extent
        let rect = CGRect(x: extent.minX + point.x * extent.width - 2, y: extent.minY + (1 - point.y) * extent.height - 2, width: 5, height: 5)
        var pixels = [Float](repeating: 0, count: 25 * 4)
        pixels.withUnsafeMutableBytes { raw in
            RenderContext.shared.render(image, toBitmap: raw.baseAddress!, rowBytes: 5 * 16, bounds: rect, format: .RGBAf,
                                        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        let r = (0..<25).map { Double(pixels[$0 * 4]) }.reduce(0, +) / 25
        let g = (0..<25).map { Double(pixels[$0 * 4 + 1]) }.reduce(0, +) / 25
        let b = (0..<25).map { Double(pixels[$0 * 4 + 2]) }.reduce(0, +) / 25
        return ColorMath.linearToOklab(max(r, 0), max(g, 0), max(b, 0))
    }

    // MARK: AI

    func computeMissingAIMasks() {
        for shape in Set(masks.flatMap(\.components).map(\.shape).filter(\.isAI)) { computeAIIfNeeded(shape) }
    }

    func computeAIIfNeeded(_ shape: MaskShape) {
        guard shape.isAI, let store = aiStore, !store.hasMask(for: shape), !computingAI.contains(shape) else { return }
        // Empty object selections wait for a tap.
        if case .object(let seeds) = shape, seeds.isEmpty { return }
        guard let session else { return }
        computingAI.insert(shape)
        aiFailures[shape] = nil
        let source = session.original
        let analysisStage = recipe.analysisStage
        let label = shape.isAIKind ? "Finding \(shape.displayName.lowercased())" : "Selecting object"
        let remote = app.remoteLibrary, recipe = self.recipe
        let task = app.jobs.run(label, detail: remote.map { "On \($0.displayName)" } ?? filename) { _ in
            if let remote {
                // The device with the photo runs Vision and sends the mask back.
                try await remote.computeAIMasks(session, recipe: recipe, into: store)
                return
            }
            let decoded = try await RawDecoder.shared.decode(source, rawStage: analysisStage, longEdge: 2560)
            try await store.compute(shape, base: decoded.image)
        }
        Task {
            do {
                try await task.value
            } catch is CancellationError {
            } catch {
                aiFailures[shape] = error.localizedDescription
                app.showToast(error.localizedDescription)
            }
            computingAI.remove(shape)
            requestRender()
        }
    }

    func aiStatus(_ shape: MaskShape) -> String? {
        guard shape.isAI else { return nil }
        if computingAI.contains(shape) { return "Analyzing…" }
        if let failure = aiFailures[shape] { return failure }
        if case .object(let seeds) = shape, seeds.isEmpty { return "Tap the photo to select an object" }
        return aiStore?.hasMask(for: shape) == true ? nil : "Not analyzed yet"
    }
}

extension MaskShape {
    var isAIKind: Bool {
        if case .ai = self { return true }
        return false
    }

    var isBrush: Bool {
        if case .brush = self { return true }
        return false
    }
}
