import EditorCore
import SwiftUI

/// The toolbar pill: a spinner and job count. Tap for the list with progress and cancel.
struct JobTrayPill: View {
    let jobs: JobCenter
    /// Show "No jobs running" when idle (Mac), or hide entirely (iPhone).
    var alwaysVisible = false
    @State private var showingTray = false

    var body: some View {
        let count = jobs.activeCount
        let photos = jobs.photosRemaining
        if count > 0 || alwaysVisible || !jobs.visibleJobs.isEmpty {
            Button {
                showingTray.toggle()
            } label: {
                HStack(spacing: 6) {
                    if count > 0 {
                        ProgressView().controlSize(.mini)
                        Text(photos > 0 ? "\(photos) photo\(photos == 1 ? "" : "s") left" : "\(count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    } else if jobs.visibleJobs.contains(where: { if case .failed = $0.state { true } else { false } }) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    } else if !jobs.visibleJobs.isEmpty {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                    } else {
                        Text("No jobs running").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(Theme.panelRaised, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(count > 0 ? (photos > 0 ? "\(photos) photos left to process" : "\(count) jobs running") : "Jobs")
            .accessibilityIdentifier("jobTray")
            .popover(isPresented: $showingTray) {
                JobTrayList(jobs: jobs)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

struct JobTrayList: View {
    let jobs: JobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jobs").font(.headline)
                Spacer()
                if jobs.photosRemaining > 0 {
                    Text("\(jobs.photosRemaining) photos left").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            if jobs.visibleJobs.isEmpty {
                Text("No jobs running").foregroundStyle(Theme.textSecondary)
            }
            ForEach(jobs.visibleJobs) { job in
                JobRow(job: job)
            }
        }
        .padding()
        .frame(minWidth: 300, alignment: .leading)
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.label).font(.subheadline.weight(.medium))
                    if let detail = job.detail {
                        Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                switch job.state {
                case .running:
                    if let progress = job.progress {
                        ProgressView(value: progress).tint(Theme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    }
                case .finished:
                    Text("Done").font(.caption).foregroundStyle(Theme.textSecondary)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(Theme.textSecondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            if job.isActive {
                Button {
                    job.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel \(job.label)")
            }
        }
    }
}

/// A brief message at the bottom of the screen, e.g. "Edits copied".
struct ToastView: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.panelRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.divider))
                .foregroundStyle(Theme.textPrimary)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("toast")
        }
    }
}
