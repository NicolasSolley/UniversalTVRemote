import SwiftUI

// PadCover.swift — pad cover art, split out of ContentView.swift in
// v1.0.53: the cover store (JPEGs in Documents), the system photo
// picker, the in-pad cropper, and the orientation fix the cropper
// needs. Internal, so SettingsSheet and the pad share them.

/// Pad cover art (v1.0.50): a user-picked photo, cropped to the
/// pad's shape in Settings, saved as JPEGs in Documents. The pad
/// reads it through a version counter in @AppStorage so it
/// re-renders when the cover changes.
enum PadCoverStore {
    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var coverURL: URL { documents.appendingPathComponent("pad-cover.jpg") }
    static var originalURL: URL { documents.appendingPathComponent("pad-cover-original.jpg") }

    private static var cachedImage: UIImage?
    private static var cachedVersion = -1

    static func image(for version: Int) -> UIImage? {
        if cachedVersion != version {
            cachedImage = UIImage(contentsOfFile: coverURL.path)
            cachedVersion = version
        }
        return cachedImage
    }

    static func loadOriginal() -> UIImage? {
        UIImage(contentsOfFile: originalURL.path)
    }

    /// Returns false when the JPEG can't be encoded or the write
    /// fails (v1.0.53): the caller surfaces that instead of
    /// silently doing nothing.
    @discardableResult
    static func saveCover(_ image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return false }
        do {
            try data.write(to: coverURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func saveOriginal(_ image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return false }
        do {
            try data.write(to: originalURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: coverURL)
        try? FileManager.default.removeItem(at: originalURL)
        cachedImage = nil
    }

    /// The pad's aspect in its normal state, computed from the
    /// layout math (v1.0.58) — the cropper's source of truth.
    /// Takes the screen width and the remote page's usable
    /// height (screen height less the safe-area insets); the
    /// layout caps the pad height, so small errors in the
    /// usable height barely move the aspect. (The old source
    /// was a stored measurement with a 0.91 fallback — but
    /// Settings lives on the devices list, so the cropper
    /// could run before the remote ever measured the pad, and
    /// the fallback framed the photo to 0.91 while the real
    /// pad is ~0.80: the cover came out zoomed in, text cut
    /// off at the edges, overflowing the pad. A computed
    /// aspect can't go stale, so the stored measurement is
    /// gone — the pad no longer writes it either.)
    static func padAspect(screenWidth: CGFloat, usableHeight: CGFloat) -> CGFloat {
        RemoteLayout.normalPadAspect(screenWidth: screenWidth, usableHeight: usableHeight)
    }
}

/// The system photo picker (v1.0.50): UIImagePickerController
/// works back to iOS 15, where PhotosPicker doesn't exist.
/// Needs NSPhotoLibraryUsageDescription in Info.plist.
struct PadCoverPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onPick: (UIImage) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Defer out of the UIKit callback (v1.0.53): swapping
            // the sheet's content synchronously inside the delegate
            // call raced the picker's dismissal and left the
            // cropper's buttons dead until the transition settled.
            // One run loop later the picker is gone and the swap
            // lands cleanly.
            if let image = info[.originalImage] as? UIImage {
                DispatchQueue.main.async { self.onPick(image) }
            } else {
                DispatchQueue.main.async { self.onCancel() }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            DispatchQueue.main.async { self.onCancel() }
        }
    }
}

/// The cropper's overlay item (v1.0.57): the cropper is no
/// longer a sheet — two sheet-based presentations failed on
/// device (v1.0.53's picker→cropper content swap, v1.0.56's
/// sequential sheets), both leaving Cancel / Set cover dead.
/// It now renders as an in-place overlay inside the Settings
/// sheet (see SettingsSheet), so there is no second
/// presentation to race or corrupt. Identifiable so the
/// overlay can show it conditionally.
struct CropTarget: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Crop a photo to the pad's shape (v1.0.50): drag to move, pinch
/// to zoom, double-tap to reset. The frame is the pad — same
/// aspect, same rounded corners — so what you see is what the pad
/// shows.
struct PadCoverCropView: View {
    let image: UIImage
    /// Called after the crop + save succeed (v1.0.53): the caller
    /// bumps the version so the pad re-reads the cover, then
    /// dismisses. The cropper owns the save, so the caller never
    /// sees a half-saved cover.
    var onSaved: () -> Void
    var onCancel: () -> Void

    /// Explicit init (v1.0.53): the synthesized memberwise init is
    /// private to this file because of the private @State properties
    /// below, so SettingsSheet in ContentView.swift needs this to
    /// construct the cropper.
    init(image: UIImage, onSaved: @escaping () -> Void, onCancel: @escaping () -> Void) {
        // Normalize orientation up front (v1.0.56): the display
        // fit math and the crop math both use image.size, and
        // for a portrait photo from the camera the raw size
        // doesn't match the rendered pixels — the photo came out
        // letterboxed in the frame instead of filling it. With
        // orientation baked in, size == rendered pixels
        // everywhere, display and crop alike.
        self.image = image.normalizedOrientation()
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero
    /// Saving state (v1.0.53): while the crop + save runs, both
    /// buttons are disabled so a cancel can't race the save — and
    /// the button reads "Saving…" so the tap visibly lands.
    @State private var isSaving = false
    /// Set when a save fails (v1.0.53): surfaces an alert instead
    /// of silently doing nothing.
    @State private var saveFailed = false

    /// The crop frame, from the sheet's geometry (v1.0.58): the
    /// width is the screen width less the pad's side padding,
    /// capped at 520; the height comes from the pad's real
    /// aspect, computed from the layout math — so the frame is
    /// the pad's shape and the saved cover fits it exactly.
    /// The usable height is the sheet height less the safe-area
    /// insets, the same height RemoteView's layout works from;
    /// the layout caps the pad height, so a few points either
    /// way barely move the aspect.
    private func frameSize(for geo: GeometryProxy) -> CGSize {
        let w = min(geo.size.width - 32, 520)
        let usableHeight = geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom
        let aspect = PadCoverStore.padAspect(screenWidth: geo.size.width, usableHeight: usableHeight)
        return CGSize(width: w, height: w / aspect)
    }
    private func fitScale(frameSize: CGSize) -> CGFloat {
        max(frameSize.width / image.size.width, frameSize.height / image.size.height)
    }
    private func totalScale(frameSize: CGSize) -> CGFloat { fitScale(frameSize: frameSize) * scale }

    private func clampedOffset(_ o: CGSize, frameSize: CGSize) -> CGSize {
        let ts = totalScale(frameSize: frameSize)
        let sw = image.size.width * ts
        let sh = image.size.height * ts
        let mx = max(0, (sw - frameSize.width) / 2)
        let my = max(0, (sh - frameSize.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx),
                      height: min(max(o.height, -my), my))
    }

    var body: some View {
        GeometryReader { geo in
            content(frameSize: frameSize(for: geo))
        }
    }

    @ViewBuilder
    private func content(frameSize: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { onCancel() } label: {
                    Text("Cancel")
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                Spacer()
                Text("Crop pad cover")
                    .font(.headline)
                Spacer()
                Button { confirmCover(frameSize: frameSize) } label: {
                    Text(isSaving ? "Saving…" : "Set cover")
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.headline)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Spacer()
            ZStack {
                // Cover, by construction (v1.0.56): scaledToFill
                // sizes the image from its rendered aspect, so
                // the photo always fills the frame — the old
                // manual frame (image.size × totalScale) letter-
                // boxed portrait photos instead of filling it.
                // The drag / pinch / clamp / crop math is
                // unchanged: scaledToFill's cover scale IS
                // fitScale, and the offset moves the same window.
                // The pinch zoom is applied as a scale effect
                // (v1.0.58): before this the display never used
                // `scale`, so pinching did nothing visible while
                // the saved crop DID zoom in — the preview lied
                // about the zoom and the pad came out more
                // zoomed than the cropper showed. scaleEffect
                // scales about the frame center, exactly what
                // the crop math assumes.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frameSize.width, height: frameSize.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: frameSize.width, height: frameSize.height)
            // Gesture scope (v1.0.57): the drag / pinch /
            // double-tap gestures belong ONLY to this frame.
            // The photo is offset by dragging, and an offset
            // photo's hit area extends past the frame — on
            // device, taps on Cancel / Set cover landed on the
            // photo instead of the buttons (single taps did
            // nothing, double-taps reset the crop). .clipped()
            // confines the photo's hit area to the frame, and
            // .contentShape(Rectangle()) makes the frame itself
            // the exact hit area — so double-tap to reset fires
            // only inside the cropped square, never on the
            // toolbar or outside the frame.
            .contentShape(Rectangle())
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.7), lineWidth: 2)
            )
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = clampedOffset(CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height), frameSize: frameSize)
                        }
                        .onEnded { _ in lastOffset = offset },
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(4, max(1, lastScale * value))
                            offset = clampedOffset(offset, frameSize: frameSize)
                        }
                        .onEnded { _ in lastScale = scale }
                )
            )
            .onTapGesture(count: 2) {
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
            }
            Spacer()
            Text("Drag to move · Pinch to zoom · Double-tap to reset")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        // Touch boundary (v1.0.57): the cropper is an overlay
        // on top of the Settings sheet — the whole overlay
        // rect is hit-testable, so taps on empty black space
        // are swallowed here instead of falling through to
        // the Settings controls underneath.
        .contentShape(Rectangle())
        .alert("Couldn't save the cover", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The photo couldn't be saved. Check storage and try again.")
        }
    }

    /// Confirm (v1.0.53): one ordered flow — crop + save the image,
    /// then bump the version so the pad re-reads it (onSaved), then
    /// dismiss. The crop + JPEG encodes run off the main thread:
    /// on the main thread they blocked the UI for up to a second,
    /// so the first tap on "Set cover" looked dead and only
    /// repeated taps worked. A failed save surfaces the alert
    /// above instead of silently doing nothing — the sheet stays
    /// up so he can try again.
    private func confirmCover(frameSize: CGSize) {
        guard !isSaving else { return }
        isSaving = true
        let image = image
        let scale = scale
        let offset = offset
        let frameSize = frameSize
        Task {
            let (originalOK, coverOK) = await Task.detached(priority: .userInitiated) {
                let cropped = Self.crop(image: image, scale: scale, offset: offset, frameSize: frameSize)
                return (PadCoverStore.saveOriginal(image), PadCoverStore.saveCover(cropped))
            }.value
            isSaving = false
            if originalOK && coverOK {
                onSaved()
            } else {
                saveFailed = true
            }
        }
    }

    /// Pure crop (v1.0.53): the crop math as a static function of
    /// its inputs, so the confirm path can run it off the main
    /// thread. The render uses UIGraphicsImageRenderer + Core
    /// Graphics, both safe off the main thread for offscreen work.
    /// Internal (not private) so tests can drive the geometry.
    static func crop(image: UIImage, scale: CGFloat, offset: CGSize, frameSize: CGSize) -> UIImage {
        let normalized = image.normalizedOrientation()
        let fitScale = max(frameSize.width / image.size.width, frameSize.height / image.size.height)
        let ts = fitScale * scale
        let vw = frameSize.width / ts
        let vh = frameSize.height / ts
        let cx = normalized.size.width / 2 - offset.width / ts
        let cy = normalized.size.height / 2 - offset.height / ts
        var rect = CGRect(x: cx - vw / 2, y: cy - vh / 2, width: vw, height: vh)
        rect.origin.x = min(max(rect.origin.x, 0), max(0, normalized.size.width - rect.width))
        rect.origin.y = min(max(rect.origin.y, 0), max(0, normalized.size.height - rect.height))
        rect.size.width = min(rect.width, normalized.size.width)
        rect.size.height = min(rect.height, normalized.size.height)
        let s = normalized.scale
        let pixelRect = CGRect(x: rect.origin.x * s, y: rect.origin.y * s,
                               width: rect.width * s, height: rect.height * s)
        guard let cg = normalized.cgImage?.cropping(to: pixelRect) else { return normalized }
        let cropped = UIImage(cgImage: cg, scale: s, orientation: .up)
        let targetW: CGFloat = 1200
        guard cropped.size.width > targetW else { return cropped }
        let k = targetW / cropped.size.width
        let size = CGSize(width: cropped.size.width * k, height: cropped.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension UIImage {
    /// Redraw with the orientation baked in, so pixel math
    /// (cropping) and point math (display) agree.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
