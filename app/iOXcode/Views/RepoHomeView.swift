import SwiftUI

/// The cover page of a project, modelled on a GitHub repository's front page: who owns it, what it is, the facts
/// (stars, language, licence), the actions, and the README underneath.
struct RepoHomeView: View {
    let project: Project
    @EnvironmentObject var model: AppModel
    @State private var origin: GitHubOrigin?
    @State private var info: RepoInfo?
    @State private var looking = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                ReadmeCard(folder: project.url)
                if ReadmeCard.find(in: project.url) == nil {
                    Text("This project has no README.").font(.footnote).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title2.bold()).lineLimit(2)
                    if let origin {
                        Text("\(origin.owner)/\(origin.repo)").font(.subheadline).foregroundColor(.secondary)
                    } else if looking {
                        Text("Looking for this project on GitHub…").font(.subheadline).foregroundColor(.secondary)
                    } else {
                        Text(project.manifest.bundleId).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let d = info?.description, !d.isEmpty {
                Text(d).font(.body)
            }
            if let info, let h = info.homepage, !h.isEmpty, let u = URL(string: h.hasPrefix("http") ? h : "https://" + h) {
                Link(destination: u) { Label(h.replacingOccurrences(of: "https://", with: ""), systemImage: "link").font(.subheadline) }
            }
            facts
            if let t = info?.topics, !t.isEmpty { topics(t) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
    }

    private var avatar: some View {
        Group {
            if let o = origin, let url = URL(string: "https://github.com/\(o.owner).png?size=140") {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
                }
            } else { placeholder }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(project.name.prefix(1)).uppercased()).font(.title.bold()).foregroundColor(.white)
        }
    }

    private var facts: some View {
        FlowRow(spacing: 8) {
            if let i = info {
                chip("star", "\(compact(i.stars))")
                chip("tuningfork", "\(compact(i.forks))")
                if i.issues > 0 { chip("exclamationmark.circle", "\(compact(i.issues))") }
                if let l = i.language { chip("chevron.left.forwardslash.chevron.right", l) }
                if let l = i.license { chip("scalemass", l) }
                if let p = i.pushed { chip("clock", "Updated " + p.formatted(date: .abbreviated, time: .omitted)) }
            }
            chip("app.badge", project.manifest.bundleId)
            if !project.manifest.version.isEmpty { chip("number", "v\(project.manifest.version)") }
        }
    }

    private func topics(_ t: [String]) -> some View {
        FlowRow(spacing: 6) {
            ForEach(t, id: \.self) { topic in
                Text(topic).font(.caption.weight(.medium)).foregroundColor(.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
            }
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundColor(.secondary).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemGroupedBackground)).clipShape(Capsule())
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : (n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)")
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button { model.build(project) } label: {
                Label(model.building ? "Building…" : "Build IPA", systemImage: "hammer.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.building)

            HStack(spacing: 10) {
                NavigationLink(destination: FileBrowserView(folder: project.url, projectRoot: project.url, title: project.name)) {
                    tile("folder", "Files")
                }
                NavigationLink(destination: ReleasesEntry(projectName: project.url.lastPathComponent)) {
                    tile("shippingbox", "Releases")
                }
                if let u = info?.url ?? origin.flatMap({ URL(string: "https://github.com/\($0.owner)/\($0.repo)") }) {
                    Link(destination: u) { tile("safari", "GitHub") }
                }
            }
        }
    }

    private func tile(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundColor(.accentColor)
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
    }

    // MARK: data

    private func load() async {
        let name = project.url.lastPathComponent
        var o = Origins.load(name)
        if o == nil {
            o = await GitHubOrigin.infer(from: project.url)
            if let o { Origins.save(o, for: name) }
        }
        origin = o
        looking = false
        if let o { info = await RepoInfo.fetch(o) }
    }
}

/// Wraps its children onto several lines, like tags on a GitHub page.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}
