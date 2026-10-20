//
//  ContentView.swift
//  PipaRender — 包列表 + ZIP 导入
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var packages: [ImportedPackage] = []
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var importing = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("渲染包").font(.caption)) {
                    if packages.isEmpty {
                        Text("还没有导入渲染包\n点右上角导入 .pipapkg.zip")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: center)
                            .padding(.vertical, 40)
                    }
                    ForEach(packages, id: \.id) { p in
                        NavigationLink(destination: PackageDetailView(package: p)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.headline)
                                Text("\(p.pkg.frameCount) 帧 · \(p.pkg.fps)fps · \(p.pkg.groups.count) 组 · \(p.pkg.characters.count) 角色 · \(p.pkg.width)×\(p.pkg.height)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete { idx in
                        for i in idx {
                            PackageStore.shared.remove(packages[i])
                        }
                        refresh()
                    }
                }
                if let msg = importMessage {
                    Section { Text(msg).foregroundColor(importing ? .secondary : .green).font(.caption) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("PipaRender")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showImporter = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                DocumentPicker { url in
                    importZip(url)
                }
            }
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        PackageStore.shared.reload()
        packages = PackageStore.shared.packages
    }

    private func importZip(_ url: URL) {
        importing = true
        importMessage = "正在导入…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try PackageStore.shared.importZip(at: url) { name, cur, total in
                    DispatchQueue.main.async {
                        self.importMessage = "解压 \(cur)/\(total)"
                    }
                }
                DispatchQueue.main.async {
                    self.importing = false
                    self.importMessage = "导入完成"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.importing = false
                    self.importMessage = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

/// ZIP 选择器（系统文件 App）
struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.zip, .item], asCopy: true)
        p.allowsMultipleSelection = false
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, UIDocumentPickerViewControllerDelegate {
        let parent: DocumentPicker
        init(_ p: DocumentPicker) { parent = p }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            parent.onPicked(u)
        }
    }
}
