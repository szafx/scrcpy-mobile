//
//  ScriptManager.swift
//  Scrcpy Remote
//
//  脚本与识图模板的持久化（2026-10-18）。
//  存储方式与项目里的 ActionManager 一致：UserDefaults + JSON。
//  模板图放 Documents/ScriptTemplates/<uuid>.png。
//

import Foundation
import UIKit

@MainActor
final class ScriptManager: ObservableObject {

    static let shared = ScriptManager()

    @Published private(set) var scripts: [RemoteScript] = []

    private let storageKey = "RemoteScripts"

    private var templatesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ScriptTemplates", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        load()
        cleanupOrphanTemplates()
    }

    // MARK: - 读写

    func script(id: UUID) -> RemoteScript? {
        scripts.first { $0.id == id }
    }

    @discardableResult
    func save(_ script: RemoteScript) -> RemoteScript {
        var copy = script
        copy.updatedAt = Date()

        if let index = scripts.firstIndex(where: { $0.id == copy.id }) {
            scripts[index] = copy
        } else {
            scripts.append(copy)
        }
        persist()
        return copy
    }

    func delete(id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        let removed = scripts.remove(at: index)
        for step in removed.steps {
            if let file = step.templateFile {
                deleteTemplate(named: file)
            }
        }
        persist()
    }

    @discardableResult
    func duplicate(_ script: RemoteScript) -> RemoteScript {
        var copy = script
        copy.id = UUID()
        copy.name = script.name + " 副本"
        copy.updatedAt = Date()

        // 模板文件也要复制一份，否则删掉原脚本会把副本的模板一起清掉
        copy.steps = script.steps.map { step in
            var newStep = step
            newStep.id = UUID()
            if let file = step.templateFile, let image = templateImage(named: file) {
                newStep.templateFile = storeTemplate(image: image)
            }
            return newStep
        }

        scripts.append(copy)
        persist()
        return copy
    }

    // MARK: - 模板文件

    /// 保存一块裁剪好的模板图，返回文件名
    func storeTemplate(image: UIImage) -> String? {
        guard let data = image.pngData() else { return nil }
        let name = UUID().uuidString + ".png"
        let url = templatesDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            print("❌ [Scripts] 模板保存失败：\(error)")
            return nil
        }
    }

    func templateImage(named name: String) -> UIImage? {
        let url = templatesDirectory.appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }

    func deleteTemplate(named name: String) {
        let url = templatesDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 内部

    private func persist() {
        do {
            let data = try JSONEncoder().encode(scripts)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("❌ [Scripts] 保存失败：\(error)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            scripts = try JSONDecoder().decode([RemoteScript].self, from: data)
        } catch {
            print("❌ [Scripts] 读取失败：\(error)")
            scripts = []
        }
    }

    /// 清掉没有被任何脚本引用的模板文件
    private func cleanupOrphanTemplates() {
        let referenced = Set(scripts.flatMap { $0.steps.compactMap { $0.templateFile } })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: templatesDirectory, includingPropertiesForKeys: nil) else { return }

        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
