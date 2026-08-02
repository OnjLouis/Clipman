import base64
import binascii
import hashlib
import json
import os
import pathlib
import struct
import tempfile
import time
import unittest
import zlib
from unittest import mock

import clipman


def png_chunk(kind, data):
    payload = kind + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", binascii.crc32(payload) & 0xffffffff)


def small_png():
    scanline = b"\x00\xff\x00\x00\xff"
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(scanline))
        + png_chunk(b"IEND", b"")
    )


def small_jpeg_header():
    return bytes.fromhex("ffd8ffc000070800010001")


def image_rich_text(data=None, mime_type="image/png"):
    data = data or small_png()
    wrapper = (
        '<img data-clipman-image="1" data-clipman-filename="Photo.png" alt="Image: Photo.png" '
        'src="data:' + mime_type + ';base64,' + base64.b64encode(data).decode("ascii") + '">'
    )
    return {"html_fragment": wrapper, "preferred_format": "Html"}


def image_rich_text_with_filename(filename, data=None, mime_type="image/png"):
    data = data or small_png()
    wrapper = (
        '<img data-clipman-image="1" data-clipman-filename="' + filename + '" '
        'alt="Image: ' + filename + '" src="data:' + mime_type + ';base64,'
        + base64.b64encode(data).decode("ascii") + '">'
    )
    return {"html_fragment": wrapper, "preferred_format": "Html"}


class LinkLabelTests(unittest.TestCase):
    def test_name_wins_and_destination_omits_scheme(self):
        label, destination = clipman.link_display_parts(
            "https://www.ableton.com/en/release-notes/move-1-beta/?tracking=ignored",
            "Move beta notes",
        )
        self.assertEqual(label, "Move beta notes")
        self.assertEqual(destination, "ableton.com/en/release-notes/move-1-beta/")
        self.assertEqual(
            clipman.link_row_text("https://example.com/path", "Doug proposal"),
            "Doug proposal; example.com/path",
        )
        self.assertEqual(
            clipman.entry_display_text({
                "section": "links", "text": "https://example.com/path", "name": "Doug proposal",
            }),
            "Doug proposal; example.com/path",
        )

    def test_generated_label_uses_host_and_meaningful_segment(self):
        label, destination = clipman.link_display_parts(
            "https://example.com/articles/accessible-clipboard-management.html"
        )
        self.assertEqual(label, "Accessible clipboard management")
        self.assertEqual(destination, "example.com/articles/accessible-clipboard-management.html")

    def test_numbered_resource_and_root_labels_are_concise(self):
        self.assertEqual(
            clipman.link_row_text("https://github.com/OnjLouis/Clipman/issues/50"),
            "Issues 50; github.com/OnjLouis/Clipman/issues/50",
        )
        self.assertEqual(
            clipman.link_row_text("https://example.com/2024/03/how-to-fix-the-thing"),
            "How to fix the thing; example.com/2024/03/how-to-fix-the-thing",
        )
        self.assertEqual(clipman.link_row_text("https://www.example.com/"), "example.com")

    def test_uuid_and_high_entropy_segments_are_skipped(self):
        label, _destination = clipman.link_display_parts(
            "https://example.com/articles/550e8400-e29b-41d4-a716-446655440000"
        )
        self.assertEqual(label, "Articles")
        label, _destination = clipman.link_display_parts(
            "https://example.com/download/aB91kLm302PQrsTUvWxyZ678"
        )
        self.assertEqual(label, "Download")

    def test_website_title_disclosure_names_the_sent_request(self):
        self.assertEqual(
            clipman.website_title_disclosure("example.com"),
            "Clipman will contact example.com once to read the page title. "
            "The website can see that it was contacted. Clipman sends the selected link request, "
            "but no cookies, credentials or other clipboard content.",
        )

    def test_exact_urls_use_link_presentation_in_every_text_section(self):
        for section, rich_text in (("text", None), ("links", None), ("rich", {"html_fragment": "<b>Link</b>"})):
            entry = {
                "section": section,
                "text": "https://github.com/OnjLouis/Clipman/issues/50",
                "name": "",
                "display": "https://github.com/OnjLouis/Clipman/issues/50",
                "rich_text": rich_text,
            }
            self.assertEqual(
                clipman.entry_display_text(entry),
                "Issues 50; github.com/OnjLouis/Clipman/issues/50",
            )
            searchable = clipman.entry_search_text(entry)
            self.assertIn("Issues 50", searchable)
            self.assertIn("https://github.com/OnjLouis/Clipman/issues/50", searchable)
            self.assertTrue(clipman.entry_display_text(entry).startswith("Issues 50"))

    def test_website_title_eligibility_is_entry_based_not_section_based(self):
        for section, rich_text in (("text", None), ("links", None), ("rich", {"html_fragment": "<b>Link</b>"})):
            entry = {"section": section, "text": "https://example.com/article", "name": "", "rich_text": rich_text}
            self.assertTrue(clipman.can_use_website_title(entry))
        self.assertFalse(clipman.can_use_website_title({"section": "text", "text": "Read https://example.com", "name": ""}))
        self.assertFalse(clipman.can_use_website_title({"section": "links", "text": "https://example.com", "name": "Existing"}))

    def test_overlong_urls_are_rejected_before_link_parsing_or_unescaping(self):
        prefix = "https://example.com/"
        exact = prefix + "a" * (clipman.MAX_LINK_URL_CHARACTERS - len(prefix))
        self.assertIsNotNone(clipman._web_link(exact))
        value = exact + "a"
        with mock.patch("urllib.parse.urlsplit", side_effect=AssertionError("URL parser was called")):
            self.assertIsNone(clipman._web_link(value))
            self.assertFalse(clipman.is_standalone_link(value))
            self.assertEqual(clipman.link_display_parts(value), ("Link", "Link"))
            self.assertEqual(clipman.clean_tracking_url(value), value)

    def test_offline_link_labels_strip_unsafe_unicode_consistently(self):
        label, destination = clipman.link_display_parts(
            "https://example.com/alpha%0Abeta%E2%80%8Dgamma%EF%BF%BDdelta",
            "  Named\tentry\u200d\ufffd\u2028\u2029  ",
        )
        self.assertEqual(label, "Namedentry")
        self.assertEqual(destination, "example.com/alphabetagammadelta")
        self.assertEqual(
            clipman._clean_link_text("Alpha\nBeta\u200dGamma\ufffdDelta\u2028Epsilon\u2029Zeta\u00a0 Eta", 200),
            "AlphaBetaGammaDeltaEpsilonZeta Eta",
        )
        self.assertEqual(clipman._clean_link_text("Good\ud800Title"), "GoodTitle")


class SensitiveDataTests(unittest.TestCase):
    def test_explicit_web_urls_do_not_trigger_token_exclusion(self):
        for value in (
            "https://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
            "HTTPS://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
        ):
            self.assertEqual(clipman.sensitive_data_match(value, ["api-token"]), "")

    def test_inferred_links_do_not_bypass_sensitive_data_detection(self):
        self.assertEqual(
            clipman.sensitive_data_match("+447890123456", ["international-phone"]),
            "International phone number",
        )
        self.assertEqual(
            clipman.sensitive_data_match("ABCDEFGHIJKLMNOPQRSTUVWXYZ123456", ["api-token"]),
            "Long API key or token",
        )


class EmbeddedImageTests(unittest.TestCase):
    def test_wrapper_recognition_and_native_clipboard_payload(self):
        rich_text = image_rich_text()
        image = clipman.parse_clipman_image(rich_text)
        self.assertIsNotNone(image)
        self.assertEqual((image["width"], image["height"]), (1, 1))
        self.assertEqual(image["filename"], "Photo.png")
        entry = {"text": "Image: Photo.png (0123456789ab)", "name": "", "rich_text": rich_text, "display": "stored"}
        self.assertEqual(clipman.entry_display_text(entry), "Image: Photo.png")
        entry["name"] = "Invoice photograph"
        self.assertEqual(clipman.entry_display_text(entry), "Invoice photograph")
        payloads = dict(clipman.clipboard_payloads("Image: Photo.png", rich_text))
        self.assertEqual(payloads["image/png"], small_png())
        self.assertIn(b"data-clipman-image", payloads["text/html"])
        fallback = "Image: Photo.png (" + hashlib.sha256(small_png()).hexdigest()[:12] + ")"
        payloads = dict(clipman.clipboard_payloads(fallback, rich_text))
        self.assertEqual(payloads["text/plain"], fallback.encode("utf-8"))

    def test_apostrophe_filename_uses_shared_canonical_escaping(self):
        rich_text = image_rich_text_with_filename("Andre's photo.png")
        image = clipman.parse_clipman_image(rich_text)
        self.assertIsNotNone(image)
        self.assertEqual(image["filename"], "Andre's photo.png")
        self.assertIn("Andre's photo.png", image["html"])
        self.assertNotIn("&#39;", image["html"])
        noncanonical = {"html_fragment": image["html"].replace("Andre's", "Andre&#39;s")}
        self.assertIsNone(clipman.parse_clipman_image(noncanonical))

    def test_filename_length_and_extension_must_be_canonical(self):
        self.assertIsNotNone(clipman.parse_clipman_image(image_rich_text_with_filename("a" * 116 + ".png")))
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename("a" * 117 + ".png")))
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename("Photo.jpg")))
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename("private:Photo.png")))
        jpeg = small_jpeg_header()
        self.assertIsNotNone(clipman.parse_clipman_image(image_rich_text_with_filename("Photo.jpg", jpeg, "image/jpeg")))
        self.assertIsNotNone(clipman.parse_clipman_image(image_rich_text_with_filename("Photo.jpeg", jpeg, "image/jpeg")))
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename("Photo.png", jpeg, "image/jpeg")))

    def test_filename_limit_uses_unicode_scalars_and_rejects_unsafe_characters(self):
        self.assertIsNotNone(clipman.parse_clipman_image(image_rich_text_with_filename("\U0001f4f7" * 116 + ".png")))
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename("\U0001f4f7" * 117 + ".png")))
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename("Photo.PNG")))
        self.assertEqual(clipman._canonical_image_filename("Photo.PNG", "image/png"), "Photo.png")
        self.assertEqual(
            clipman._canonical_image_filename("  photo\t\u00a0\u2003\u2028\u2029note.PNG  ", "image/png"),
            "photo note.png",
        )
        self.assertEqual(clipman._canonical_image_filename("photo\u001cnote.PNG", "image/png"), "photonote.png")
        for filename in ("bad\x01name.png", "bad\u200fname.png", "bad\u202ename.png", "bad\u2028name.png", "bad\ud800name.png", "two  spaces.png"):
            self.assertIsNone(clipman.parse_clipman_image(image_rich_text_with_filename(filename)))

    def test_external_active_and_noncanonical_images_are_rejected(self):
        invalid = [
            {"html_fragment": '<img src="https://example.com/photo.png">'},
            {"html_fragment": '<img data-clipman-image="1" data-clipman-filename="x.svg" alt="x" src="data:image/svg+xml;base64,AAAA">'},
            {"html_fragment": image_rich_text()["html_fragment"].replace(" alt=", ' onclick="run()" alt=')},
            {"html_fragment": image_rich_text()["html_fragment"] + "<script>run()</script>"},
            image_rich_text_with_filename("/home/user/private/Photo.png"),
            image_rich_text_with_filename("content:provider/photo.png"),
        ]
        for rich_text in invalid:
            self.assertIsNone(clipman.parse_clipman_image(rich_text))

    def test_stored_size_limit_is_enforced(self):
        oversized = small_png() + b"\x00" * clipman.MAX_STORED_IMAGE_BYTES
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text(oversized)))

    def test_animation_marker_must_be_a_real_png_chunk(self):
        ordinary = small_png()[:-12] + png_chunk(b"tEXt", b"word=acTL") + small_png()[-12:]
        self.assertIsNotNone(clipman.parse_clipman_image(image_rich_text(ordinary)))
        animated = small_png()[:-12] + png_chunk(b"acTL", struct.pack(">II", 1, 0)) + small_png()[-12:]
        self.assertIsNone(clipman.parse_clipman_image(image_rich_text(animated)))

    def test_file_clipboard_name_uses_capture_date_device_and_original_format(self):
        entry = {"created_unix_ms": 1_700_000_000_000, "device": 'Phone/One: "Photo"'}
        image = {"filename": "Original.jpeg", "mime": "image/jpeg", "data": small_jpeg_header()}
        with mock.patch("time.localtime", return_value=time.struct_time((2023, 11, 14, 22, 13, 20, 1, 318, 0))):
            filename = clipman.image_clipboard_filename(entry, image)
        self.assertEqual(filename, "2023-11-14 22-13-20 - PhoneOne Photo.jpeg")

    def test_file_clipboard_payload_uses_gnome_and_uri_list_contracts(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "Photo with space.png")
            payloads = dict(clipman.image_file_clipboard_payloads(path))
        self.assertEqual(payloads["x-special/gnome-copied-files"], b"copy\nfile://" + path.replace(" ", "%20").encode("utf-8"))
        self.assertEqual(payloads["x-special/mate-copied-files"], b"copy\nfile://" + path.replace(" ", "%20").encode("utf-8"))
        self.assertEqual(payloads["text/uri-list"], b"file://" + path.replace(" ", "%20").encode("utf-8") + b"\r\n")

    def test_clipboard_image_cache_preserves_bytes_and_removes_previous_file(self):
        with tempfile.TemporaryDirectory() as folder:
            stale_directory = pathlib.Path(folder) / "clipman-linux" / "clipboard-images"
            stale_directory.mkdir(parents=True)
            stale_file = stale_directory / "stale.png"
            stale_file.write_bytes(b"stale")
            cache = clipman.ClipboardImageFileCache(folder)
            self.assertFalse(stale_file.exists())
            first = {"filename": "Photo.png", "mime": "image/png", "data": small_png()}
            first_path = cache.materialize(first, {"created_unix_ms": 1_000, "device": "Phone"})
            self.assertEqual(first_path.read_bytes(), small_png())
            self.assertEqual(first_path.stat().st_mode & 0o777, 0o600)
            second_data = small_jpeg_header()
            second = {"filename": "Photo.jpg", "mime": "image/jpeg", "data": second_data}
            second_path = cache.materialize(second, {"created_unix_ms": 2_000, "device": "Tablet"})
            self.assertFalse(first_path.exists())
            self.assertEqual(second_path.read_bytes(), second_data)
            self.assertEqual([path.name for path in cache.directory.iterdir()], [second_path.name])
            cache.clear()
            self.assertFalse(second_path.exists())

    def test_local_image_file_candidate_and_bounded_reader_preserve_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            png = root / "Camera metadata.PNG"
            original = small_png()[:-12] + png_chunk(b"tEXt", b"location=retained") + small_png()[-12:]
            png.write_bytes(original)
            path, mime_type = clipman.local_image_file_candidate([str(png)])
            self.assertEqual((path, mime_type), (str(png), "image/png"))
            self.assertEqual(clipman.read_bounded_local_image_file(path), original)

            jpeg = root / "Photo.JPEG"
            jpeg.write_bytes(small_jpeg_header())
            self.assertEqual(clipman.local_image_file_candidate([str(jpeg)]), (str(jpeg), "image/jpeg"))

    def test_local_image_file_candidate_rejects_unsupported_multiple_and_directories(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            png = root / "photo.png"
            png.write_bytes(small_png())
            text = root / "notes.txt"
            text.write_text("not an image", encoding="utf-8")
            for paths, message in (
                ([], "does not contain a local file"),
                ([str(png), str(text)], "multiple files"),
                ([str(root)], "Folders cannot"),
                ([str(text)], "Only local PNG and JPEG"),
            ):
                with self.subTest(paths=paths), self.assertRaisesRegex(ValueError, message):
                    clipman.local_image_file_candidate(paths)

            empty = root / "empty.png"
            empty.touch()
            with self.assertRaisesRegex(ValueError, "empty"):
                clipman.read_bounded_local_image_file(empty)
            oversized = root / "large.jpg"
            oversized.write_bytes(b"12345")
            with self.assertRaisesRegex(ValueError, "larger"):
                clipman.read_bounded_local_image_file(oversized, 4)

    def test_explicit_and_automatic_file_image_policy_are_independent(self):
        values = {
            "rich_text_history_enabled": True,
            "include_images_in_rich_text_history": True,
            "add_copied_image_files_to_rich_text_history": False,
        }
        self.assertTrue(clipman.should_import_file_as_rich_image(values, "rich", True))
        self.assertFalse(clipman.should_import_file_as_rich_image(values, "text", True))
        self.assertFalse(clipman.should_import_file_as_rich_image(values, "rich", False))
        values["add_copied_image_files_to_rich_text_history"] = True
        self.assertTrue(clipman.should_import_file_as_rich_image(values, "text", False))
        values["include_images_in_rich_text_history"] = False
        self.assertFalse(clipman.should_import_file_as_rich_image(values, "rich", True))
        self.assertFalse(clipman.should_import_file_as_rich_image(values, "text", False))


class PreferenceTests(unittest.TestCase):
    def test_image_capture_is_cleared_when_rich_text_is_disabled(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": folder}):
            settings = os.path.join(folder, "clipman-linux", "settings.json")
            os.makedirs(os.path.dirname(settings))
            with open(settings, "w", encoding="utf-8") as stream:
                json.dump({"rich_text_history_enabled": False, "include_images_in_rich_text_history": True}, stream)
            preferences = clipman.Preferences()
            self.assertFalse(preferences.values["include_images_in_rich_text_history"])
            self.assertFalse(preferences.values["add_copied_image_files_to_rich_text_history"])

            payloads = dict(clipman.clipboard_payloads("Image: Photo.png", image_rich_text()))
            self.assertEqual(payloads["image/png"], small_png())

    def test_copied_image_file_preference_persists_only_with_both_parents(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": folder}):
            settings = pathlib.Path(folder) / "clipman-linux" / "settings.json"
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({
                "rich_text_history_enabled": True,
                "include_images_in_rich_text_history": True,
                "add_copied_image_files_to_rich_text_history": True,
            }), encoding="utf-8")
            preferences = clipman.Preferences()
            self.assertTrue(preferences.values["add_copied_image_files_to_rich_text_history"])
            preferences.save()
            self.assertTrue(json.loads(settings.read_text(encoding="utf-8"))["add_copied_image_files_to_rich_text_history"])

            settings.write_text(json.dumps({
                "rich_text_history_enabled": True,
                "include_images_in_rich_text_history": False,
                "add_copied_image_files_to_rich_text_history": True,
            }), encoding="utf-8")
            preferences = clipman.Preferences()
            self.assertFalse(preferences.values["add_copied_image_files_to_rich_text_history"])

    def test_image_metadata_disclosure_explains_privacy_tradeoff(self):
        self.assertIn("camera or location information", clipman.IMAGE_METADATA_DISCLOSURE)
        self.assertIn("history encryption and sync choices", clipman.IMAGE_METADATA_DISCLOSURE)


if __name__ == "__main__":
    unittest.main()
