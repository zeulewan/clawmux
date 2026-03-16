import SwiftUI

// MARK: - Notes Placeholder (full implementation via Nova)

// Stub — Nova replaces this with full /api/notes implementation
struct NotesPanelView: View {
    let baseURL: URL?
    let onDismiss: () -> Void

    @State private var nowText: String = ""
    @State private var laterText: String = ""
    @State private var activeTab: String = "now"
    @State private var saveStatus: String = ""
    @State private var pendingSave: DispatchWorkItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker — matches web notes-tabs
                Picker("Tab", selection: $activeTab) {
                    Text("Now").tag("now")
                    Text("Later").tag("later")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

                // Editor
                if activeTab == "now" {
                    TextEditor(text: $nowText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cText)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 12)
                        .onChange(of: nowText) { _, _ in scheduleSave() }
                } else {
                    TextEditor(text: $laterText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cText)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 12)
                        .onChange(of: laterText) { _, _ in scheduleSave() }
                }

                // Save indicator — matches web .notes-save-indicator
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.cTextTer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { onDismiss() } } }
            .onAppear { loadNotes() }
            .onDisappear { saveNotes() }
        }
        .background(Color.clear)
        // iOS 26: system provides liquid glass sheet automatically — no presentationBackground needed
        // iOS <26: apply material fallback
        .modifier(SheetBackgroundModifier())
    }

    private func scheduleSave() {
        saveStatus = "Saving…"
        pendingSave?.cancel()
        let work = DispatchWorkItem { saveNotes() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func loadNotes() {
        guard let url = baseURL?.appendingPathComponent("api/notes") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                nowText   = json["now"]   as? String ?? ""
                laterText = json["later"] as? String ?? ""
                saveStatus = ""
            }
        }.resume()
    }

    private func saveNotes() {
        guard let url = baseURL?.appendingPathComponent("api/notes") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["now": nowText, "later": laterText])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                saveStatus = ok ? "Saved" : "Save failed"
                if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" } }
            }
        }.resume()
    }
}
