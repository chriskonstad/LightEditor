import CoreImage
import EditorCore
import Foundation

/// Retouch: painting spots, picking sources, and AI fills.
extension EditorModel {
    var retouches: [RetouchSpot] { recipe.retouches }

    var selectedSpot: RetouchSpot? {
        guard let selectedSpotID else { return nil }
        return retouches.first { $0.id == selectedSpotID }
    }

    /// Paints the in-progress retouch stroke (kept out of the recipe until release).
    /// `zoomFactor` is how much bigger the photo is on screen than at Fit: the
    /// brush keeps its size on screen, so zooming in paints finer.
    func beginRetouchStroke(at point: NormalizedPoint, zoomFactor: CGFloat = 1) {
        paintingStroke = BrushStroke(points: [point], radius: retouchBrushSize / max(zoomFactor, 1), feather: 0.35)
    }

    /// Drops a stroke in progress, e.g. when a second finger starts a pinch.
    func cancelRetouchStroke() {
        paintingStroke = nil
    }

    func extendRetouchStroke(to point: NormalizedPoint) {
        guard var stroke = paintingStroke else { return }
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < stroke.radius * 0.15 { return }
        stroke.points.append(point)
        paintingStroke = stroke
    }

    /// Turns the finished stroke into a spot: heal and clone pick a source
    /// automatically, Remove starts the AI fill.
    func endRetouchStroke() {
        guard let stroke = paintingStroke?.simplified() else { return }
        paintingStroke = nil
        var spot = RetouchSpot(order: recipe.nextRetouchOrder, kind: retouchKind, strokes: [stroke], engine: removeEngine)
        if spot.kind.needsSource {
            spot.sourceOffset = autoSourceOffset(for: spot)
        }
        let added = spot
        updateRecipe(spot.kind.displayName) { recipe, stamp in recipe.setRetouch(added, at: stamp) }
        selectedSpotID = spot.id
        if spot.kind == .remove { computeMissingInpaints() }
    }

    private func autoSourceOffset(for spot: RetouchSpot) -> NormalizedPoint {
        guard let decoded = base,
              let image = RenderContext.shared.createCGImage(
                  decoded.image.transformed(by: CGAffineTransform(scaleX: 512 / decoded.size.width, y: 512 / decoded.size.width)),
                  from: CGRect(x: 0, y: 0, width: 512, height: (512 * decoded.size.height / decoded.size.width).rounded(.down)),
                  format: .RGBA8, colorSpace: RenderContext.sRGB)
        else { return NormalizedPoint(x: spot.bounds.width * 1.4, y: 0) }
        return RetouchRenderer.autoSource(for: spot, in: image)
    }

    func moveSpotSource(_ id: UUID, to offset: NormalizedPoint, commit: Bool) {
        guard var spot = retouches.first(where: { $0.id == id }) else { return }
        spot.sourceOffset = offset
        let moved = spot
        updateRecipe(commit ? "Move source" : nil) { recipe, stamp in recipe.setRetouch(moved, at: stamp) }
    }

    func deleteSpot(_ id: UUID) {
        updateRecipe("Delete spot") { recipe, stamp in recipe.removeRetouch(id, at: stamp) }
        if selectedSpotID == id { selectedSpotID = retouches.last?.id }
        // Later Remove fills depended on this spot; recompute them.
        computeMissingInpaints()
    }

    func setSpotKind(_ id: UUID, _ kind: RetouchSpot.Kind) {
        guard var spot = retouches.first(where: { $0.id == id }), spot.kind != kind else { return }
        spot.kind = kind
        if kind.needsSource, spot.sourceOffset == nil { spot.sourceOffset = autoSourceOffset(for: spot) }
        let changed = spot
        updateRecipe("Change to \(kind.displayName)") { recipe, stamp in recipe.setRetouch(changed, at: stamp) }
        computeMissingInpaints()
    }

    func clearRetouches() {
        updateRecipe("Clear retouch") { recipe, stamp in
            for spot in recipe.retouches { recipe.removeRetouch(spot.id, at: stamp) }
        }
        selectedSpotID = nil
    }

    // MARK: AI fills

    /// Computes every Remove fill that isn't cached yet, in order, as one job.
    func computeMissingInpaints() {
        guard let store = inpaintStore, let session else { return }
        let spots = retouches
        // Skip spots that already failed, so a missing model or a bad fill isn't retried forever.
        let missing = spots.indices.filter {
            spots[$0].kind == .remove && inpaintFailures[spots[$0].id] == nil
                && !store.hasPatch(for: RetouchRenderer.chainKey(spots[...$0]))
        }
        guard !missing.isEmpty else { return }
        guard Inpainter.shared.isAvailable || app.remoteLibrary != nil else {
            for index in missing { inpaintFailures[spots[index].id] = InpaintError.modelUnavailable.localizedDescription }
            return
        }
        let ids = Set(missing.map { spots[$0].id })
        guard inpainting.isDisjoint(with: ids) else { return }
        inpainting.formUnion(ids)
        let source = session.original
        let recipe = self.recipe
        let engines = Set(missing.map { spots[$0].engine })
        let how = engines == [.fast] ? "" : engines.contains(.diffusion) ? " with diffusion" : " at full resolution"
        let label = missing.count == 1 ? "Removing\(how)" : "Removing \(missing.count) areas\(how)"
        let filename = self.filename
        let remote = app.remoteLibrary
        let task = app.jobs.run(label, detail: filename) { reporter in
            if let remote {
                // The device with the original fills from it and sends the fills back.
                try await remote.computeFills(session, recipe: recipe, into: store) { fraction, detail in
                    reporter.progress(fraction, detail: "\(filename) · on \(remote.displayName)\(detail.map { " · \($0)" } ?? "")")
                }
                return
            }
            let decoded = try await RawDecoder.shared.decode(source, rawStage: recipe.analysisStage, longEdge: 2560)
            try await store.prepare(recipe, preview: decoded.image, fullResolution: {
                reporter.progress(nil, detail: "\(filename) · reading the full-resolution original")
                return try await RawDecoder.shared.lazyImage(source, rawStage: recipe.analysisStage, longEdge: nil).0
            }, progress: { done, total in
                reporter.progress(Double(done) / Double(max(total, 1)), detail: total > 1 ? "\(filename) · \(done + 1) of \(total)" : filename)
            }, stepProgress: { fraction in
                // Diffusion reports each step, so the tray shows it moving.
                reporter.progress(fraction, detail: "\(filename) · diffusion \(Int(fraction * 100))%")
            })
        }
        Task {
            do {
                try await task.value
            } catch is CancellationError {
            } catch {
                for id in ids { inpaintFailures[id] = error.localizedDescription }
                app.showToast(error.localizedDescription)
            }
            inpainting.subtract(ids)
            requestRender()
            // Spots added while this ran get their own pass.
            computeMissingInpaints()
        }
    }

    func spotStatus(_ spot: RetouchSpot) -> String? {
        guard spot.kind == .remove else { return nil }
        if inpainting.contains(spot.id) {
            switch spot.engine {
            case .standard: return "Filling from the full-resolution original…"
            case .fast: return "Filling…"
            case .diffusion: return "LaMa, then diffusion… about 30 s"
            }
        }
        if let failure = inpaintFailures[spot.id] { return failure }
        switch spot.engine {
        case .standard: return "Up to \(Inpainter.shared.fullSize) px from the full-resolution original."
        case .fast: return "512 px from the preview."
        case .diffusion: return spot.variation == 0 ? "LaMa, then diffusion at 512 px." : "LaMa, then diffusion · variation \(spot.variation + 1)."
        }
    }

    /// Asks diffusion for a different fill of the same spot.
    func tryAnotherFill(_ id: UUID) {
        guard var spot = retouches.first(where: { $0.id == id }), spot.engine == .diffusion else { return }
        spot.variation += 1
        inpaintFailures[id] = nil
        let changed = spot
        updateRecipe("Try another fill") { recipe, stamp in recipe.setRetouch(changed, at: stamp) }
        computeMissingInpaints()
    }

    /// Refills a spot with another engine.
    func setSpotEngine(_ id: UUID, _ engine: RemoveEngine) {
        guard var spot = retouches.first(where: { $0.id == id }), spot.engine != engine else { return }
        spot.engine = engine
        removeEngine = engine
        inpaintFailures[id] = nil
        let changed = spot
        updateRecipe("Remove with \(engine.displayName)") { recipe, stamp in recipe.setRetouch(changed, at: stamp) }
        computeMissingInpaints()
    }
}
