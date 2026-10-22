import Testing
import Foundation
import CryptoKit
import UniformTypeIdentifiers
@testable import ResectaApp

// The posture the Photos door keeps: no photo-library access, no usage
// string, an unchanged privacy manifest, no generic image type anywhere,
// and the two surfaces the door adds — the notice once per image import
// and the launch hook that opens a bundled synthetic image.

@Suite("Photo import posture", .tags(.importFlow))
struct PhotoImportPostureTests {

    @Test("The privacy manifest is unchanged: no tracking, nothing collected, the two accessed-API reasons")
    func privacyManifestUnchanged() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("Resources/PrivacyInfo.xcprivacy"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "e2f64e48a4b725d8625e556e4a396e66976c23fdb249f6aee143963e9d1bdf16",
                "the privacy manifest's bytes moved: \(digest)")
        let manifest = String(decoding: data, as: UTF8.self)
        #expect(manifest.contains("CA92.1") && manifest.contains("C617.1"), "the two accessed-API reasons")
        #expect(!manifest.contains("NSPrivacyAccessedAPICategoryPhotos"), "no photo-library access reason")
    }

    @Test("No photo-library access and no usage string")
    func noPhotoLibraryAccess() throws {
        for file in try swiftFiles(under: "Sources/ResectaApp") {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("PHPhotoLibrary"), "\(file.lastPathComponent) names the photo library")
            #expect(!text.contains("photoLibrary:"), "\(file.lastPathComponent) passes a photo library")
        }
        let project = try loadRepoFile("project.yml")
        #expect(!project.contains("NSPhotoLibraryUsageDescription:"), "no usage string")
    }

    @Test("Exactly one file imports PhotosUI and mounts the picker")
    func onePhotosUISurface() throws {
        var importers: [String] = [], mounts: [String] = []
        for file in try swiftFiles(under: "Sources/ResectaApp") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("import PhotosUI") { importers.append(file.lastPathComponent) }
            if text.contains(".photosPicker(") { mounts.append(file.lastPathComponent) }
        }
        #expect(importers == ["PhotoImportPicker.swift"], "\(importers)")
        #expect(mounts == ["PhotoImportPicker.swift"], "\(mounts)")
    }

    @Test("The notice fires for an image import and not for a PDF")
    func noticeOncePerImageImport() {
        var facts = ImportFacts.Summary()
        #expect(RedactWorkspaceView.imageSourceToast(facts: facts) == nil)
        facts.origin = .images(count: 3)
        let message = RedactWorkspaceView.imageSourceToast(facts: facts)
        #expect(message == "Image pages are read with on-device text recognition. Barcodes and QR codes are not read.")
        facts.origin = .pdf
        #expect(RedactWorkspaceView.imageSourceToast(facts: facts) == nil)
    }

    @Test("The launch hook names the bundled synthetic image")
    func launchHookResolvesTheSynthetic() throws {
        #expect(ResectaApp.testImageName(for: ["--uitesting"]) == nil)
        #expect(ResectaApp.testImageName(for: ["--uitesting", "--loadTestImage"]) == "uitest_image")
        #expect(ResectaApp.testImageName(for: ["--uitesting", "--loadTestImage", "uitest_image"]) == "uitest_image")
        #expect(ResectaApp.testImageName(for: ["--loadTestImage=other", "--uitesting"]) == "other")
        #expect(ResectaApp.testImageName(for: ["--loadTestImage", "--uitesting"]) == "uitest_image")
        let root = repoRoot()
        for name in ["uitest_image.jpg", "uitest_image.heic"] {
            let url = root.appendingPathComponent("UITestFixtures/\(name)")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 0 && size <= 200 * 1024, "\(name) is \(size) bytes")
        }
    }

    @Test("The accepted content types are PDF, JPEG, PNG, HEIC and HEIF, never the generic image")
    func acceptedContentTypes() throws {
        #expect(ImportService.acceptedContentTypes == [.pdf, .jpeg, .png, .heic, .heif])
        #expect(ImportService.acceptedImageTypes == [.jpeg, .png, .heic, .heif])
        #expect(!ImportService.acceptedContentTypes.contains(.image))
    }

    // MARK: - Helpers

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under relativePath: String) throws -> [URL] {
        let root = repoRoot().appendingPathComponent(relativePath)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }
}
