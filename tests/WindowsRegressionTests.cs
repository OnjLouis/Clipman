using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace Clipman.Tests
{
    internal static class WindowsRegressionTests
    {
        private static int failures;

        [STAThread]
        private static int Main()
        {
            Run("database container caps are aligned", DatabaseContainerCapsAreAligned);
            Run("bounded exact reads handle partial streams", BoundedExactReadsHandlePartialStreams);
            Run("encrypted database round trip", EncryptedDatabaseRoundTrip);
            Run("URL length is bounded before presentation or fetch", UrlLengthIsBounded);
            Run("website title safety distinguishes readable slugs from capability tokens", WebsiteTitleSafetyDistinguishesReadableSlugs);
            Run("link labels remove unsafe Unicode categories", LinkLabelsRemoveUnsafeUnicode);
            Run("image preview is keyboard focusable and accessible", ImagePreviewIsKeyboardFocusable);
            Run("embedded image clipboard includes an Explorer file drop", EmbeddedImageClipboardIncludesExplorerFileDrop);
            Run("embedded image file-drop cache cleanup is bounded", EmbeddedImageFileDropCacheCleanupIsBounded);
            Run("copied image files use the bounded Rich Text image path", CopiedImageFilesUseBoundedRichTextPath);
            Run("single-modifier hotkey warning preference defaults and round trips", SingleModifierHotkeyWarningPreferenceDefaultsAndRoundTrips);
            Run("history window constructs before an entry is selected", HistoryWindowConstructsWithoutSelection);
            Run("name and content copy formatting is deterministic", NameAndContentCopyFormattingIsDeterministic);
            Run("ClipMerge requires a deliberate matching second clipboard event", ClipMergeRequiresMatchingSecondEvent);
            Run("ClipMerge coalesces duplicates and rejects stale cut sources", ClipMergeCoalescesDuplicatesAndRejectsStaleCuts);
            Run("ClipMerge rejects mixed and mismatched file operations", ClipMergeRejectsUnsafeCombinations);
            Run("ClipMerge settings are conservative", ClipMergeSettingsAreConservative);
            Run("ClipMerge replaces partial entries without modifying pins", ClipMergePreservesPinnedEntriesAndRemovesPartials);
            Run("ClipMerge combines file events without retaining a partial", ClipMergeCombinesFileEvents);
            Run("shared executable updates require install-local settings", SharedExecutableUpdatesRequireInstallLocalSettings);

            Console.WriteLine(failures == 0 ? "All Windows regression tests passed." : failures + " Windows regression test(s) failed.");
            return failures == 0 ? 0 : 1;
        }

        private static void DatabaseContainerCapsAreAligned()
        {
            Assert(ServerStorageClient.MaximumServerTransferBytes == 272L * 1024L * 1024L,
                "The client server-transfer cap should be exactly 272 MiB.");
            Assert(ClipDatabaseFile.MaximumLocalDatabaseFileBytes == ServerStorageClient.MaximumServerTransferBytes,
                "Local and server-transfer container compatibility should remain aligned.");
            Assert(ClipDatabaseFile.MaximumLocalDatabaseFileBytes > ClipDatabaseFile.MaximumDecompressedDatabaseBytes,
                "The local container limit must allow bounded encryption and compression overhead.");
            ClipDatabaseFile.ValidateLocalDatabaseFileLength(ServerStorageClient.MaximumServerTransferBytes);
            ServerStorageClient.ValidateServerTransferLength(ServerStorageClient.MaximumServerTransferBytes);
            Expect<InvalidDataException>(() => ClipDatabaseFile.ValidateLocalDatabaseFileLength(ClipDatabaseFile.MaximumLocalDatabaseFileBytes + 1));
            Expect<InvalidDataException>(() => ServerStorageClient.ValidateServerTransferLength(ServerStorageClient.MaximumServerTransferBytes + 1));
        }

        private static void BoundedExactReadsHandlePartialStreams()
        {
            var expected = Enumerable.Range(0, 41).Select(value => (byte)value).ToArray();
            using (var stream = new PartialReadStream(expected, 3))
            {
                var actual = ClipDatabaseFile.ReadExact(stream, expected.Length);
                Assert(expected.SequenceEqual(actual), "ReadExact did not preserve data returned in partial reads.");
            }
            using (var stream = new PartialReadStream(new byte[] { 1, 2, 3 }, 1))
            {
                Expect<EndOfStreamException>(() => ClipDatabaseFile.ReadExact(stream, 4));
            }
            Expect<ArgumentOutOfRangeException>(() => ClipDatabaseFile.ReadExact(new MemoryStream(), -1));
        }

        private static void EncryptedDatabaseRoundTrip()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var path = Path.Combine(directory, "history.clipdb");
                var database = new ClipDatabase();
                database.Entries.Add(new ClipEntry { Text = "Encrypted round trip", Name = "Test entry" });
                ClipDatabaseFile.SaveAtomic(path, database, "correct horse battery staple");
                var restored = ClipDatabaseFile.Load(path, "correct horse battery staple");
                Assert(restored.Entries.Count == 1 && restored.Entries[0].Text == "Encrypted round trip",
                    "The encrypted database did not round trip through the bounded reader.");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void UrlLengthIsBounded()
        {
            const string prefix = "https://example.com/";
            var maximum = prefix + new string('a', LinkPresentation.MaximumUrlCharacters - prefix.Length);
            var overlong = maximum + "a";
            Uri uri;
            Assert(maximum.Length == 8192 && LinkPresentation.TryGetUri(maximum, out uri), "An URL at the documented boundary should remain valid.");
            Assert(!LinkPresentation.TryGetUri(overlong, out uri), "An overlong URL reached URI presentation parsing.");

            var parsedOverlong = new Uri(overlong, UriKind.Absolute);
            string reason;
            Assert(!LinkTitleFetcher.CanOffer(parsedOverlong, out reason), "An overlong URL was offered for website-title retrieval.");
            Assert(reason.IndexOf("8192", StringComparison.Ordinal) >= 0, "The overlong URL rejection was not useful to the user.");
            Assert(LinkPresentation.Destination(parsedOverlong).Length == 0, "An overlong URL reached destination unescaping.");
            Assert(LinkPresentation.OfflineLabel(parsedOverlong).Length == 0, "An overlong URL reached offline-label parsing.");
        }

        private static void LinkLabelsRemoveUnsafeUnicode()
        {
            var unsafeText = "Alpha\u200BBeta\uD800\uFFFD\u0000Gamma\u2028Delta\u2029Epsilon \uD83D\uDE00";
            const string expected = "AlphaBeta Gamma Delta Epsilon \uD83D\uDE00";
            var offline = LinkPresentation.SanitizeLabel(unsafeText, 200);
            var title = LinkTitleFetcher.SanitizeTitle(unsafeText);
            Assert(offline == expected, "Offline label sanitization produced an unexpected value: " + offline);
            Assert(title == expected, "Website title sanitization was not consistent with offline labels: " + title);
            Assert(!ContainsForbiddenLabelCharacter(offline), "Offline label retained a prohibited Unicode category.");
            Assert(!ContainsForbiddenLabelCharacter(title), "Website title retained a prohibited Unicode category.");
        }

        private static void WebsiteTitleSafetyDistinguishesReadableSlugs()
        {
            var readable = new Uri("https://example.org/a-long-human-readable-article-title-with-2026-and-many-words?utm_source=share");
            var readableWithArticleID = new Uri("https://nautil.us/a-new-toad-species-emerges-from-the-la-brea-tar-pits-1283396?utm_source=firefox-newtab-en-gb");
            var readableWithPrefixedArticleID = new Uri("https://www.independent.co.uk/news/science/monkeys-primates-friendships-animals-b3028129.html?utm_source=firefox-newtab-en-gb");
            var opaque = new Uri("https://example.org/download/Az19Qw82Er73Ty64Ui50Op21Lm98Qr76");
            var uuid = new Uri("https://example.org/download/550e8400-e29b-41d4-a716-446655440000");
            var reset = new Uri("https://example.org/page?reset_token=value");
            Assert(!LinkTitleFetcher.IsCapabilityUrl(readable), "A readable article slug was mistaken for a private capability URL.");
            Assert(!LinkTitleFetcher.IsCapabilityUrl(readableWithArticleID), "A readable article slug with a numeric article ID was mistaken for a private capability URL.");
            Assert(!LinkTitleFetcher.IsCapabilityUrl(readableWithPrefixedArticleID), "A readable article filename with a prefixed numeric ID was mistaken for a private capability URL.");
            Assert(LinkTitleFetcher.IsCapabilityUrl(opaque), "An uninterrupted opaque path token was accepted.");
            Assert(LinkTitleFetcher.IsCapabilityUrl(uuid), "A UUID-like path token was accepted.");
            Assert(LinkTitleFetcher.IsCapabilityUrl(reset), "A reset-token query was accepted.");
        }

        private static void ImagePreviewIsKeyboardFocusable()
        {
            using (var image = new Bitmap(12, 34))
            using (var form = new Form())
            using (var preview = new FocusableImagePreview(image, "Image preview, receipt.png, 12 by 34 pixels", "image/png."))
            {
                form.ShowInTaskbar = false;
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-32000, -32000);
                form.Controls.Add(preview);
                preview.Dock = DockStyle.Fill;
                form.Show();
                Application.DoEvents();
                preview.Select();
                Application.DoEvents();
                Assert(preview.TabStop && preview.CanSelect && preview.Focused, "The image preview cannot receive keyboard focus.");
                Assert(preview.AccessibilityObject.Role == AccessibleRole.Graphic, "The image preview does not expose a graphic role.");
                Assert(preview.AccessibilityObject.Name == "Image preview, receipt.png, 12 by 34 pixels",
                    "The image preview accessible name does not expose its name and dimensions.");
                form.Close();
            }
        }

        private static void EmbeddedImageClipboardIncludesExplorerFileDrop()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            byte[] png;
            using (var image = new Bitmap(2, 3))
            using (var stream = new MemoryStream())
            {
                image.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
                png = stream.ToArray();
            }
            var payload = new RichTextPayload
            {
                Version = 1,
                HtmlFragment = RichImageData.BuildHtml(png, "image/png", "Clipboard image.png", "Image: Clipboard image.png"),
                PreferredFormat = "Html"
            };
            var entry = new ClipEntry
            {
                Text = RichImageData.FallbackText("Clipboard image.png", png),
                SourceMachine = "Studio/PC:*?",
                CreatedUnixMs = TimeUtil.ToUnixMs(new DateTime(2026, 8, 2, 14, 5, 6, DateTimeKind.Local)),
                RichText = payload
            };
            var data = new DataObject();
            try
            {
                RichTextData.AddToDataObject(data, payload, entry, directory, new DateTime(2026, 8, 2, 14, 5, 6, DateTimeKind.Utc));

                Assert(data.GetDataPresent(DataFormats.Bitmap, false), "The ordinary image clipboard representation was lost.");
                Assert(data.GetDataPresent(DataFormats.Html, false), "The rich HTML clipboard representation was lost.");
                Assert(data.GetDataPresent(DataFormats.FileDrop, false), "The Explorer file-drop representation is missing.");
                var files = data.GetFileDropList();
                Assert(files.Count == 1, "CF_HDROP did not expose exactly one managed image path.");
                var path = files[0];
                Assert(File.ReadAllBytes(path).SequenceEqual(png), "The Explorer file representation did not preserve the stored PNG bytes.");
                Assert(Path.GetFileName(path) == "Clipman image 2026-08-02 14-05-06 - StudioPC.png",
                    "The Explorer filename was not stable and sanitized: " + Path.GetFileName(path));
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void EmbeddedImageFileDropCacheCleanupIsBounded()
        {
            var root = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            var now = new DateTime(2026, 8, 2, 14, 5, 6, DateTimeKind.Utc);
            try
            {
                var stale = Path.Combine(root, "stale");
                Directory.CreateDirectory(stale);
                File.WriteAllBytes(Path.Combine(stale, "old.png"), new byte[] { 1 });
                Directory.SetLastWriteTimeUtc(stale, now - RichImageFileDropData.MaximumAge - TimeSpan.FromMinutes(1));

                var contents = new byte[RichImageData.MaximumStoredImageBytes];
                for (var index = 0; index < RichImageFileDropData.MaximumRetainedDirectories + 1; index++)
                {
                    RichImageFileDropData.CreateManagedFile(contents, "image-" + index + ".png", root, now);
                }

                var retained = Directory.GetDirectories(root);
                Assert(!Directory.Exists(stale), "Expired clipboard image files were not removed.");
                Assert(retained.Length <= RichImageFileDropData.MaximumRetainedDirectories,
                    "The clipboard image cache retained too many directories: " + retained.Length);
                var retainedBytes = retained.SelectMany(Directory.GetFiles).Sum(path => new FileInfo(path).Length);
                Assert(retainedBytes <= RichImageFileDropData.MaximumRetainedBytes,
                    "The clipboard image cache exceeded its byte limit: " + retainedBytes);
                Expect<ArgumentException>(() => RichImageFileDropData.CreateManagedFile(
                    new byte[RichImageData.MaximumStoredImageBytes + 1], "oversized.png", root, now));
            }
            finally
            {
                Directory.Delete(root, true);
            }
        }

        private static void CopiedImageFilesUseBoundedRichTextPath()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var pngPath = Path.Combine(directory, "Holiday photo.png");
            var mismatchedPath = Path.Combine(directory, "not-really-jpeg.jpg");
            try
            {
                byte[] png;
                using (var image = new Bitmap(4, 5))
                using (var stream = new MemoryStream())
                {
                    image.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
                    png = stream.ToArray();
                }
                File.WriteAllBytes(pngPath, png);
                File.WriteAllBytes(mismatchedPath, png);

                var capture = RichImageData.CaptureFromFile(pngPath);
                Assert(capture != null, "A valid copied PNG file was not accepted.");
                RichImageInfo decoded;
                Assert(RichImageData.TryDescribe(capture.RichText, out decoded), "The copied PNG did not produce a valid embedded image.");
                using (decoded)
                {
                    Assert(decoded.FileName == "Holiday photo.png", "The copied image filename was not preserved.");
                    Assert(decoded.Data.SequenceEqual(png), "An already-compliant copied PNG was needlessly rewritten.");
                }
                Assert(RichImageData.CaptureFromFile(mismatchedPath) == null, "A mismatched image extension and payload was accepted.");
                Assert(!new AppSettings().AutoAddImageFilesToRichText, "Automatic copied-image duplication must default to off.");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void SingleModifierHotkeyWarningPreferenceDefaultsAndRoundTrips()
        {
            Assert(new AppSettings().ConfirmSingleModifierHotkeys,
                "New settings must warn before saving a single-modifier global hotkey.");
            Assert(JsonUtil.Deserialize<AppSettings>("{}").ConfirmSingleModifierHotkeys,
                "Settings created before the preference existed must retain the warning by default.");

            var settings = new AppSettings { ConfirmSingleModifierHotkeys = false };
            var restored = JsonUtil.Deserialize<AppSettings>(JsonUtil.SerializePretty(settings));
            Assert(!restored.ConfirmSingleModifierHotkeys,
                "Suppressing the single-modifier warning did not survive settings serialization.");
        }

        private static void HistoryWindowConstructsWithoutSelection()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                using (var store = new ClipStore(Path.Combine(directory, "history.clipdb")))
                using (var form = new HistoryForm(
                    store,
                    new AppSettings(),
                    () => { },
                    () => { },
                    entry => { },
                    entries => { },
                    (text, entries) => true,
                    () => { },
                    () => { },
                    () => new System.Collections.Generic.List<ClipboardEventSummary>(),
                    ids => 0,
                    () => 0,
                    () => 0,
                    id => false,
                    (ids, offset) => { },
                    () => true,
                    () => { },
                    () => { },
                    () => { },
                    () => { },
                    () => { },
                    () => string.Empty))
                {
                    Assert(form.MainMenuStrip != null, "The history window did not finish constructing its menu.");
                    var textList = (ListView)typeof(HistoryForm)
                        .GetField("list", BindingFlags.Instance | BindingFlags.NonPublic)
                        .GetValue(form);
                    var fileList = (ListView)typeof(HistoryForm)
                        .GetField("fileEventsList", BindingFlags.Instance | BindingFlags.NonPublic)
                        .GetValue(form);
                    Assert(textList.AccessibleName == "Text history",
                        "The text history list did not expose its current section name.");
                    Assert(string.IsNullOrEmpty(textList.AccessibleDescription),
                        "The text history list exposed stale keyboard instructions to screen readers.");
                    Assert(fileList.AccessibleName == "File history",
                        "The file history list did not expose its current section name.");
                    Assert(string.IsNullOrEmpty(fileList.AccessibleDescription),
                        "The file history list exposed verbose keyboard instructions to screen readers.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void NameAndContentCopyFormattingIsDeterministic()
        {
            var entries = new[]
            {
                new ClipEntry { Name = " Release notes ", Text = "https://example.com/release" },
                new ClipEntry { Text = "Unnamed text" }
            };
            Assert(
                HistoryForm.BuildNameAndContentText(entries) == "Release notes\r\nhttps://example.com/release\r\n\r\nUnnamed text",
                "Name and content copy did not place the name before its content or separate entries with one blank line.");

            var template = new ClipEntry { Name = "Year", Text = "{{year_full}}", IsTemplate = true };
            Assert(
                HistoryForm.BuildNameAndContentText(new[] { template }) == "Year\r\n" + DateTime.Now.Year.ToString(CultureInfo.InvariantCulture),
                "Name and content copy did not resolve template text at use time.");
        }

        private static void ClipMergeRequiresMatchingSecondEvent()
        {
            var detector = new ClipMergeDetector();
            var first = Observation(ClipMergeKind.Text, "Paragraph A", "Writer", "", "a");
            Assert(!detector.Observe(first, 1000, true, 500, false).ShouldMerge, "The first observed clipboard item merged without a base.");
            detector.SetCurrentHistoryId("a");
            var secondSelection = Observation(ClipMergeKind.Text, "Paragraph B", "Writer", "", "b");
            Assert(!detector.Observe(secondSelection, 5000, true, 500, false).ShouldMerge, "The first tap on a new selection merged.");
            detector.SetCurrentHistoryId("b");
            var decision = detector.Observe(Observation(ClipMergeKind.Text, "Paragraph B", "Writer", "", ""), 5450, true, 500, false);
            Assert(decision.ShouldMerge, "A matching second tap inside the window did not merge.");
            Assert(decision.Base.HistoryId == "a" && decision.FirstTap.HistoryId == "b", "ClipMerge lost the base or partial history identity.");

            detector.Reset();
            detector.Observe(Observation(ClipMergeKind.Text, "A", "Writer", "", ""), 1000, true, 500, false);
            detector.Observe(Observation(ClipMergeKind.Text, "B", "Writer", "", ""), 2000, true, 500, false);
            Assert(!detector.Observe(Observation(ClipMergeKind.Text, "B", "Browser", "", ""), 2200, true, 500, false).ShouldMerge,
                "Matching text from a different application merged.");
            Assert(!detector.Observe(Observation(ClipMergeKind.Text, "B", "Writer", "", ""), 5000, true, 500, false).ShouldMerge,
                "A clipboard repeat outside the merge window merged.");
        }

        private static void ClipMergeRejectsUnsafeCombinations()
        {
            var detector = new ClipMergeDetector();
            detector.Observe(Observation(ClipMergeKind.Text, "A", "Writer", "", ""), 1000, true, 500, false);
            detector.Observe(Observation(ClipMergeKind.Files, "one", "Explorer", "Copy", ""), 2000, true, 500, false);
            Assert(!detector.Observe(Observation(ClipMergeKind.Files, "one", "Explorer", "Copy", ""), 2200, true, 500, false).ShouldMerge,
                "A file selection merged onto text.");

            detector.Reset();
            detector.Observe(Observation(ClipMergeKind.Files, "base", "Explorer", "Move", ""), 1000, true, 500, false);
            detector.Observe(Observation(ClipMergeKind.Files, "next", "Explorer", "Copy", ""), 2000, true, 500, false);
            Assert(!detector.Observe(Observation(ClipMergeKind.Files, "next", "Explorer", "Copy", ""), 2200, true, 500, false).ShouldMerge,
                "Copy files merged onto a cut clipboard.");

            detector.Reset();
            detector.Observe(Observation(ClipMergeKind.Text, "A", "Writer", "", ""), 1000, true, 500, false);
            detector.Observe(Observation(ClipMergeKind.Text, "B", "Writer", "", ""), 2000, true, 500, false);
            Assert(!detector.Observe(Observation(ClipMergeKind.Text, "B", "Writer", "", ""), 2200, true, 500, true).ShouldMerge,
                "A deliberate one-shot save activated ClipMerge.");
        }

        private static void ClipMergeCoalescesDuplicatesAndRejectsStaleCuts()
        {
            var detector = new ClipMergeDetector();
            detector.Observe(Observation(ClipMergeKind.Text, "A", "Writer", "", "a"), 1000, true, 500, false);
            detector.SetCurrentHistoryId("a");
            var firstCopy = Observation(ClipMergeKind.Text, "B", "Writer", "", "b");
            firstCopy.ChangeIdentifier = 20;
            detector.Observe(firstCopy, 2000, true, 500, false);
            detector.SetCurrentHistoryId("b");
            var repeatedNotification = Observation(ClipMergeKind.Text, "B", "Writer", "", "");
            repeatedNotification.ChangeIdentifier = 20;
            var duplicate = detector.Observe(repeatedNotification, 2040, true, 500, false);
            Assert(duplicate.SuppressDuplicate && !duplicate.ShouldMerge,
                "One copy command reported twice was treated as a deliberate ClipMerge gesture.");
            var secondCopy = Observation(ClipMergeKind.Text, "B", "Writer", "", "");
            secondCopy.ChangeIdentifier = 21;
            var deliberateSecondCopy = detector.Observe(secondCopy, 2050, true, 500, false);
            Assert(deliberateSecondCopy.ShouldMerge,
                "A new clipboard sequence was suppressed merely because the deliberate second copy arrived quickly.");

            detector.Reset();
            detector.Observe(Observation(ClipMergeKind.Text, "A", "Thunderbird", "", "a"), 1000, true, 1000, false);
            detector.SetCurrentHistoryId("a");
            var mozillaFirst = Observation(ClipMergeKind.Text, "B", "Thunderbird", "", "b");
            mozillaFirst.ChangeIdentifier = 30;
            detector.Observe(mozillaFirst, 2000, true, 1000, false);
            detector.SetCurrentHistoryId("b");
            var mozillaAutomaticRepeat = Observation(ClipMergeKind.Text, "B", "Thunderbird", "", "");
            mozillaAutomaticRepeat.ChangeIdentifier = 31;
            Assert(detector.Observe(mozillaAutomaticRepeat, 2250, true, 1000, false).SuppressDuplicate,
                "Thunderbird's delayed second clipboard write was treated as a deliberate merge gesture.");
            var mozillaDeliberateRepeat = Observation(ClipMergeKind.Text, "B", "Thunderbird", "", "");
            mozillaDeliberateRepeat.ChangeIdentifier = 32;
            Assert(detector.Observe(mozillaDeliberateRepeat, 2800, true, 1000, false).ShouldMerge,
                "A later deliberate Mozilla copy remained blocked after the fixed duplicate guard expired.");

            var directory = Path.Combine(Path.GetTempPath(), "ClipmanCutMerge-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var oldPath = Path.Combine(directory, "old.txt");
                var newPath = Path.Combine(directory, "new.txt");
                File.WriteAllText(oldPath, "old");
                File.WriteAllText(newPath, "new");

                detector.Reset();
                var firstCut = Observation(ClipMergeKind.Files, "old", "Explorer", "Move", "old");
                firstCut.ChangeIdentifier = 30;
                detector.Observe(firstCut, 3000, true, 500, false);
                var repeatedCutObservation = Observation(ClipMergeKind.Files, "old", "Explorer", "Move", "");
                repeatedCutObservation.ChangeIdentifier = 30;
                var repeatedCut = detector.Observe(repeatedCutObservation, 3100, true, 500, false);
                Assert(!repeatedCut.ShouldMerge && repeatedCut.SuppressDuplicate,
                    "A duplicate cut notification was not coalesced.");
                var nextCut = Observation(ClipMergeKind.Files, "new", "Explorer", "Move", "new");
                nextCut.ChangeIdentifier = 40;
                detector.Observe(nextCut, 4000, true, 500, false);
                var repeatedNextCut = Observation(ClipMergeKind.Files, "new", "Explorer", "Move", "");
                repeatedNextCut.ChangeIdentifier = 41;
                var liveCutMerge = detector.Observe(repeatedNextCut, 4010, true, 500, false);
                Assert(liveCutMerge.ShouldMerge, "Two live cut selections could not enter ClipMerge.");
                Assert(ClipMergeFilePolicy.AreSourcesAvailable(new[] { oldPath, newPath }), "Existing cut sources were rejected.");
                File.Delete(oldPath);
                Assert(!ClipMergeFilePolicy.AreSourcesAvailable(new[] { oldPath, newPath }), "A moved cut source was still considered mergeable.");
                detector.RetainFirstTap(liveCutMerge.FirstTap);
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void ClipMergeSettingsAreConservative()
        {
            var settings = new AppSettings();
            Assert(!settings.ClipMergeEnabled, "ClipMerge must default to off.");
            Assert(settings.ConfirmWebsiteTitleRequests, "Manual website-title requests must ask by default.");
            Assert(!settings.AutoNameCopiedWebsiteLinks, "Automatic website-title naming must default to off.");
            Assert(settings.ClipMergeWindowMilliseconds == 500, "ClipMerge must default to a 500 millisecond window.");
            Assert(ClipMergeDetector.NormalizeWindow(1) == 200 && ClipMergeDetector.NormalizeWindow(9999) == 2000,
                "ClipMerge window bounds are not enforced.");
            Assert(ClipMergeDetector.ResolveSeparator("NewLine", "") == Environment.NewLine, "The default separator is not one new line.");
            Assert(ClipMergeDetector.ResolveSeparator("Custom", "\\n--\\t") == "\n--\t", "Custom separator escapes were not decoded.");
        }

        private static void SharedExecutableUpdatesRequireInstallLocalSettings()
        {
            var root = Path.Combine(Path.GetTempPath(), "ClipmanSharedUpdate-" + Guid.NewGuid().ToString("N"));
            var appDirectory = Path.Combine(root, "Clipman");
            var executablePath = Path.Combine(appDirectory, "clipman.exe");
            var localSettings = Path.Combine(appDirectory, "Settings");
            var externalSettings = Path.Combine(root, "Syncthing", "Clipman");
            Directory.CreateDirectory(appDirectory);
            Directory.CreateDirectory(localSettings);
            Directory.CreateDirectory(externalSettings);
            File.WriteAllText(executablePath, "test executable");
            try
            {
                Assert(SharedUpdateStateStore.CanCoordinateExecutable(localSettings, executablePath),
                    "Install-local Settings was not allowed to coordinate its executable.");
                Assert(!SharedUpdateStateStore.CanCoordinateExecutable(externalSettings, executablePath),
                    "A separately synchronized data folder was allowed to coordinate a local executable.");

                SharedUpdateStateStore.PublishCurrentBuild(externalSettings, executablePath);
                Assert(!File.Exists(SharedUpdateStateStore.StatePath(externalSettings)),
                    "A separately synchronized data folder received executable update state.");

                JsonUtil.SaveAtomic(SharedUpdateStateStore.StatePath(externalSettings), new SharedUpdateState
                {
                    BuildStampUtcMs = BuildInfo.BuildStampUtcMs + 1000,
                    ExeSha256 = "a newer executable hash",
                    UpdatedByMachine = "Other machine"
                });
                SharedUpdateState ignoredState;
                string ignoredReason;
                Assert(!SharedUpdateStateStore.ShouldRestartForState(externalSettings, executablePath, out ignoredState, out ignoredReason) && ignoredState == null,
                    "Newer state in a separate data folder could still stop the local client.");

                SharedUpdateStateStore.PublishCurrentBuild(localSettings, executablePath);
                var localState = SharedUpdateStateStore.Load(localSettings);
                Assert(localState.BuildStampUtcMs == BuildInfo.BuildStampUtcMs && !string.IsNullOrWhiteSpace(localState.ExeSha256),
                    "Install-local executable state did not publish normally.");

                JsonUtil.SaveAtomic(SharedUpdateStateStore.StatePath(localSettings), new SharedUpdateState
                {
                    BuildStampUtcMs = BuildInfo.BuildStampUtcMs + 1000,
                    UpdatedByMachine = "Other machine"
                });
                SharedUpdateState newerState;
                string newerReason;
                Assert(SharedUpdateStateStore.ShouldRestartForState(localSettings, executablePath, out newerState, out newerReason),
                    "Install-local newer state no longer requests a restart.");

                var syncthingConflict = Path.Combine(localSettings, "clipman-shared-state.sync-conflict-20260806-120000-OTHER.json");
                JsonUtil.SaveAtomic(syncthingConflict, new SharedUpdateState
                {
                    BuildStampUtcMs = BuildInfo.BuildStampUtcMs + 2000,
                    UpdatedAtUtcMs = TimeUtil.NowUnixMs() + 1000,
                    UpdatedByMachine = "Other machine"
                });
                var mergedState = SharedUpdateStateStore.Load(localSettings);
                Assert(mergedState.BuildStampUtcMs == BuildInfo.BuildStampUtcMs + 2000 && !File.Exists(syncthingConflict),
                    "A Syncthing shared-state conflict was not normalized.");

                File.WriteAllText(SharedUpdateStateStore.StatePath(localSettings), "{ incomplete json", Encoding.UTF8);
                var malformed = SharedUpdateStateStore.Load(localSettings);
                Assert(malformed != null && malformed.BuildStampUtcMs == 0,
                    "Malformed shared update state was not ignored safely.");
            }
            finally
            {
                Directory.Delete(root, true);
            }
        }

        private static void ClipMergePreservesPinnedEntriesAndRemovesPartials()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                using (var store = new ClipStore(Path.Combine(directory, "history.clipdb"), string.Empty, "Test device"))
                {
                    var pinnedBase = store.AddText("First", "KeepBoth", 100, 0);
                    store.SetPinned(pinnedBase.Id, true);
                    var partial = store.AddText("Second", "KeepBoth", 100, 0);
                    var saved = store.MergeCapturedText(pinnedBase.Id, partial.Id, "First\r\nSecond", 100, 0, "Writer");
                    var entries = store.GetEntries();
                    Assert(saved != null && saved.Id == partial.Id, "A pinned base was modified instead of using the unpinned partial entry.");
                    Assert(entries.Count == 2, "The pinned base or merged entry was lost.");
                    Assert(entries.Any(item => item.Id == pinnedBase.Id && item.Pinned && item.Text == "First"), "The pinned base changed during merge.");
                    Assert(entries.Any(item => item.Id == partial.Id && !item.Pinned && item.Text == "First\r\nSecond"), "The partial entry was not replaced by merged text.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void ClipMergeCombinesFileEvents()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var store = new FileClipboardEventStore(Path.Combine(directory, "file-history.json"), () => string.Empty);
                var first = store.Add(FileEvent("C:\\one.txt"));
                var partial = store.Add(FileEvent("C:\\two.txt"));
                var merged = FileEvent("C:\\one.txt", "C:\\two.txt");
                var saved = store.MergeCapturedEvents(first.Id, partial.Id, merged);
                var events = store.GetEvents();
                Assert(saved != null && saved.Id == first.Id, "The existing unpinned file event was not reused.");
                Assert(events.Count == 1, "The partial file event remained after merge.");
                Assert(events[0].Files.Count == 2 && events[0].Files.Contains("C:\\one.txt") && events[0].Files.Contains("C:\\two.txt"),
                    "The merged file event did not retain both unique paths.");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static ClipboardEventSummary FileEvent(params string[] paths)
        {
            return new ClipboardEventSummary
            {
                CapturedAt = DateTime.Now,
                Source = "Explorer",
                Operation = "Copy",
                SourceMachine = "Test device",
                ContainsText = true,
                FileCount = paths.Length,
                Files = paths.ToList(),
                Formats = new List<string> { "FileDrop" }
            };
        }

        private static ClipMergeObservation Observation(ClipMergeKind kind, string signature, string source, string operation, string historyId)
        {
            return new ClipMergeObservation
            {
                Kind = kind,
                Signature = signature,
                SourceApplication = source,
                Operation = operation,
                HistoryId = historyId,
                Payload = signature
            };
        }

        private static bool ContainsForbiddenLabelCharacter(string value)
        {
            for (var index = 0; index < value.Length; index++)
            {
                var character = value[index];
                if (char.IsHighSurrogate(character) && index + 1 < value.Length && char.IsLowSurrogate(value[index + 1]))
                {
                    index++;
                    continue;
                }
                if (character == '\uFFFD' || char.IsSurrogate(character)) return true;
                var category = char.GetUnicodeCategory(character);
                if (category == UnicodeCategory.Format || category == UnicodeCategory.Control ||
                    category == UnicodeCategory.LineSeparator || category == UnicodeCategory.ParagraphSeparator) return true;
            }
            return false;
        }

        private static void Run(string name, Action test)
        {
            try
            {
                test();
                Console.WriteLine("PASS: " + name);
            }
            catch (Exception ex)
            {
                failures++;
                Console.WriteLine("FAIL: " + name + ": " + ex.Message);
            }
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }

        private static void Expect<TException>(Action action) where TException : Exception
        {
            try
            {
                action();
            }
            catch (TException)
            {
                return;
            }
            throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
        }

        private sealed class PartialReadStream : MemoryStream
        {
            private readonly int maximumRead;

            public PartialReadStream(byte[] value, int maximumRead)
                : base(value)
            {
                this.maximumRead = maximumRead;
            }

            public override int Read(byte[] buffer, int offset, int count)
            {
                return base.Read(buffer, offset, Math.Min(count, maximumRead));
            }
        }
    }
}
