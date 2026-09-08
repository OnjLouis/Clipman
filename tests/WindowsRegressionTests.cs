using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Net;
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
            Run("server polls cannot overlap and respect failure backoff", ServerPollSchedulingIsBounded);
            Run("storage retries contain network failures", StorageRetriesContainNetworkFailures);
            Run("existing instances have a dedicated recovery signal", ExistingInstancesHaveRecoverySignal);
            Run("paste input keeps Control active through V", PasteInputKeepsControlActiveThroughV);
            Run("bounded exact reads handle partial streams", BoundedExactReadsHandlePartialStreams);
            Run("encrypted database round trip", EncryptedDatabaseRoundTrip);
            Run("URL length is bounded before presentation or fetch", UrlLengthIsBounded);
            Run("URL labels accept characters that are illegal in Windows paths", UrlLabelsAcceptWindowsPathCharacters);
            Run("website title safety distinguishes readable slugs from capability tokens", WebsiteTitleSafetyDistinguishesReadableSlugs);
            Run("link labels remove unsafe Unicode categories", LinkLabelsRemoveUnsafeUnicode);
            Run("runtime logs rotate with a bounded generation count", RuntimeLogsRotateWithBoundedGenerations);
            Run("image preview is keyboard focusable and accessible", ImagePreviewIsKeyboardFocusable);
            Run("embedded image clipboard includes an Explorer file drop", EmbeddedImageClipboardIncludesExplorerFileDrop);
            Run("embedded image file-drop cache cleanup is bounded", EmbeddedImageFileDropCacheCleanupIsBounded);
            Run("copied image files use the bounded Rich Text image path", CopiedImageFilesUseBoundedRichTextPath);
            Run("Quick Paste snapshots avoid opaque OLE clipboard formats", QuickPasteSnapshotAvoidsOpaqueOleFormats);
            Run("single-modifier hotkey warning preference defaults and round trips", SingleModifierHotkeyWarningPreferenceDefaultsAndRoundTrips);
            Run("history window constructs before an entry is selected", HistoryWindowConstructsWithoutSelection);
            Run("name and content copy formatting is deterministic", NameAndContentCopyFormattingIsDeterministic);
            Run("multiple-entry separators are configurable", MultipleEntrySeparatorsAreConfigurable);
            Run("bursts of Windows clipboard notifications settle on the newest sequence", ClipboardNotificationsSettleOnNewestSequence);
            Run("duplicate Windows clipboard notifications are processed once", ClipboardNotificationStateRejectsDuplicateWindowsNotifications);
            Run("application-specific clipboard compatibility is centralised", ClipboardApplicationCompatibilityIsCentralised);
            Run("clipboard flood protection is source-specific and recovers", ClipboardFloodProtectionIsSourceSpecificAndRecovers);
            Run("ClipMerge requires a deliberate matching second clipboard event", ClipMergeRequiresMatchingSecondEvent);
            Run("ClipMerge coalesces duplicates and rejects stale cut sources", ClipMergeCoalescesDuplicatesAndRejectsStaleCuts);
            Run("ClipMerge rejects mixed and mismatched file operations", ClipMergeRejectsUnsafeCombinations);
            Run("ClipMerge settings are conservative", ClipMergeSettingsAreConservative);
            Run("ClipMerge replaces partial entries without modifying pins", ClipMergePreservesPinnedEntriesAndRemovesPartials);
            Run("ClipMerge combines file events without retaining a partial", ClipMergeCombinesFileEvents);
            Run("shared executable updates require install-local settings", SharedExecutableUpdatesRequireInstallLocalSettings);
            Run("command-line history operations use the active storage database", CommandLineHistoryOperationsUseActiveStorageDatabase);
            Run("Send To accepts known extensionless text files", SendToAcceptsKnownExtensionlessTextFiles);
            Run("running history reloads explicit external changes", RunningHistoryReloadsExplicitExternalChanges);
            Run("command-line entries retain the configured device identity", CommandLineEntriesRetainConfiguredDeviceIdentity);
            Run("command-line clipboard handoff is exact, consumable, and bounded", CommandLineClipboardHandoffIsBounded);
            Run("channel identity matches the cross-client fixture", ChannelIdentityMatchesCrossClientFixture);
            Run("the go sync rules fixture corpus decodes into the expected view", GoSyncRulesFixtureCorpusDecodesIntoExpectedView);
            Run("sync rule channel keys follow the normalized grammar", SyncRuleChannelKeyGrammar);
            Run("sync rule routing honors first-match and AND semantics", SyncRuleRoutingFirstMatchAndAndSemantics);
            Run("sync rule subscriptions resolve per device", SyncRuleSubscriptions);
            Run("sync rules document round trips through JSON", SyncRulesDocumentJsonRoundTrip);
            Run("sync rules documents merge with last-writer-wins", SyncRulesMergeDocumentsLastWriterWins);
            Run("future sync rules documents are read-only and parsed leniently", SyncRulesLenientParsingAndReadOnlyDocuments);
            Run("sync rules route entries into channel files on save", RulesRouteEntriesIntoChannelFilesOnSave);
            Run("sync rules disabled keeps a single database file", RulesDisabledKeepsSingleDatabaseFile);
            Run("a group change relocates an entry between channel files", GroupChangeRelocatesEntryBetweenChannelFiles);
            Run("cross-channel tombstones suppress only matching text", CrossChannelTombstonesSuppressOnlyMatchingText);
            Run("unsubscribed channel files are not loaded into the view", UnsubscribedChannelFileIsNotLoadedIntoView);
            Run("dirty hashes skip rewriting untouched channel files", DirtyHashSkipsRewritingUntouchedChannelFiles);
            Run("relocations write the target file before the source", RelocationWritesTargetFileBeforeSource);
            Run("sync rules round trip through the store", SyncRulesRoundTripThroughStore);
            Run("routing stops at the first matching route even when unresolvable", RouteStopsAtUnresolvableFirstMatch);
            Run("read-only rules never relocate resident entries", ReadOnlyRulesNeverRelocateResidentEntries);
            Run("channel conflict copies are merged into the channel file", ChannelConflictCopiesAreMergedIntoTheChannelFile);
            Run("a channel file is never consumed as another channel's conflict copy", ChannelFilesAreNeverConsumedAsConflictCopies);
            Run("removing a channel relocates its entries first", RemovingAChannelRelocatesItsEntries);
            Run("removing a channel this device cannot see is refused", RemovingAChannelThisDeviceCannotSeeIsRefused);
            Run("a folded-storage-name collision loads but cannot be saved", FoldedStorageNameCollisionLoadsButCannotBeSaved);
            Run("sync rule summary text is stable", SyncRuleSummaryTextIsStable);

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

        private static void StorageRetriesContainNetworkFailures()
        {
            var fileReloaded = false;
            var result = StorageRetryOperation.Execute(
                delegate { throw new WebException("The operation has timed out", WebExceptionStatus.Timeout); },
                delegate { fileReloaded = true; });

            Assert(!result.Succeeded, "A timed-out server reload was reported as successful.");
            Assert(fileReloaded, "A text/server timeout prevented the independent file-history retry.");
            Assert(result.Error != null && result.Error.Message.IndexOf("timed out", StringComparison.OrdinalIgnoreCase) >= 0,
                "The retry result did not retain a useful timeout explanation.");
        }

        private static void ExistingInstancesHaveRecoverySignal()
        {
            Assert(!string.IsNullOrWhiteSpace(Program.RecoverEventName),
                "Existing-instance recovery does not have a named signal.");
            Assert(!string.Equals(Program.RecoverEventName, Program.ShowEventName, StringComparison.Ordinal),
                "Recovery was collapsed into the ordinary show-history signal.");
        }

        private static void PasteInputKeepsControlActiveThroughV()
        {
            var inputs = KeyboardInput.BuildControlVPasteInputs();
            var expectedInputSize = IntPtr.Size == 8 ? 40 : 28;
            Assert(System.Runtime.InteropServices.Marshal.SizeOf(typeof(NativeMethods.Input)) == expectedInputSize,
                "The Windows INPUT structure does not include the full native union layout.");
            Assert(inputs.Length == 4, "The paste chord was not emitted as one four-event input batch.");
            Assert(inputs[0].Keyboard.VirtualKey == NativeMethods.VK_CONTROL && inputs[0].Keyboard.Flags == 0,
                "Control was not pressed first.");
            Assert(inputs[1].Keyboard.VirtualKey == NativeMethods.VK_V && inputs[1].Keyboard.Flags == 0,
                "V was not pressed while Control remained down.");
            Assert(inputs[2].Keyboard.VirtualKey == NativeMethods.VK_V && inputs[2].Keyboard.Flags == NativeMethods.KEYEVENTF_KEYUP,
                "V was not released before Control.");
            Assert(inputs[3].Keyboard.VirtualKey == NativeMethods.VK_CONTROL && inputs[3].Keyboard.Flags == NativeMethods.KEYEVENTF_KEYUP,
                "Control was not released last.");
        }

        private static void CommandLineHistoryOperationsUseActiveStorageDatabase()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var settingsStore = new SettingsStore(directory);
                var configuredPath = Path.Combine(directory, "configured-history.clipdb");
                var settings = new AppSettings { DatabasePath = configuredPath, StorageMode = "File" };
                Assert(settingsStore.EffectiveTextHistoryDatabasePath(settings) == configuredPath,
                    "File storage did not retain the configured history database path.");

                settings.StorageMode = "Server";
                var serverPath = settingsStore.EffectiveTextHistoryDatabasePath(settings);
                Assert(!string.Equals(serverPath, configuredPath, StringComparison.OrdinalIgnoreCase),
                    "Server storage incorrectly selected the configured file-storage database.");
                Assert(serverPath.EndsWith(Path.Combine("ServerCache", Environment.MachineName, "clipman-history.clipdb"), StringComparison.OrdinalIgnoreCase),
                    "Server storage selected an unexpected cache database path: " + serverPath);
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void SendToAcceptsKnownExtensionlessTextFiles()
        {
            Assert(Program.IsSupportedTextFile("README"), "An extensionless README should be accepted by Send To.");
            Assert(Program.IsSupportedTextFile("license"), "An extensionless LICENSE should be accepted by Send To.");
            Assert(Program.IsSupportedTextFile("notes.txt"), "A .txt file should be accepted by Send To.");
            Assert(!Program.IsSupportedTextFile("unknown-extensionless-file"),
                "An arbitrary extensionless file should not be assumed to contain text.");

            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var databasePath = Path.Combine(directory, "history.clipdb");
                var files = new Dictionary<string, string>
                {
                    { "README", "Extensionless readme content" },
                    { "notes.txt", "Plain text content" },
                    { "notes.md", "Markdown content" }
                };
                var import = typeof(Program).GetMethod("ImportFile", BindingFlags.Static | BindingFlags.NonPublic);
                Assert(import != null, "The Send To import entry point could not be found.");
                var settings = new AppSettings { DuplicateMode = "MoveToTop", MaxHistoryEntries = 100, MaxHistoryDays = 0 };
                using (var store = new ClipStore(databasePath, string.Empty))
                {
                    foreach (var pair in files)
                    {
                        var path = Path.Combine(directory, pair.Key);
                        File.WriteAllText(path, pair.Value);
                        var imported = (ClipEntry)import.Invoke(null, new object[] { store, path, settings });
                        Assert(imported != null, "Send To rejected " + pair.Key + ".");
                    }

                    var importedText = new HashSet<string>(store.GetEntries().Select(entry => entry.Text), StringComparer.Ordinal);
                    foreach (var expected in files.Values)
                    {
                        Assert(importedText.Contains(expected), "Send To did not persist expected text: " + expected);
                    }
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void RunningHistoryReloadsExplicitExternalChanges()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var databasePath = Path.Combine(directory, "history.clipdb");
                using (var runningStore = new ClipStore(databasePath, string.Empty))
                {
                    using (var commandStore = new ClipStore(databasePath, string.Empty))
                    {
                        commandStore.AddText("Explicit external import", "MoveToTop", 100, 0);
                    }

                    runningStore.ReloadExternalChangeAndSync();
                    Assert(runningStore.GetEntries().Any(entry => entry.Text == "Explicit external import"),
                        "The running store did not ingest a command-line history change.");
                    Assert(!runningStore.LastChangeWasExternal,
                        "A same-device command-line addition was incorrectly reported as a remote change.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void CommandLineEntriesRetainConfiguredDeviceIdentity()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var databasePath = Path.Combine(directory, "history.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Configured device"))
                {
                    var local = store.AddText("Command-line device identity", "MoveToTop", 100, 0);
                    Assert(local != null &&
                        local.Text == "Command-line device identity" &&
                        local.SourceMachine == "Configured device",
                        "A command-line entry was not attributed to the configured device.");
                    Assert(store.GetNewestRemoteEntry("Configured device") == null,
                        "A command-line entry from this device was incorrectly classified as remote.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void CommandLineClipboardHandoffIsBounded()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var path = Path.Combine(directory, "pending-command-entry.json");
                InstanceStateStore.PublishPendingCommandEntry(path, "exact-entry-id");
                Assert(InstanceStateStore.TakePendingCommandEntry(path, 60000) == "exact-entry-id",
                    "The command handoff did not return the exact imported entry ID.");
                Assert(!File.Exists(path), "The command handoff was not consumed after being read.");
                Assert(InstanceStateStore.TakePendingCommandEntry(path, 60000) == string.Empty,
                    "A consumed command handoff was returned more than once.");

                JsonUtil.SaveAtomic(path, new PendingCommandEntry
                {
                    EntryId = "stale-entry-id",
                    CreatedAtUtcMs = TimeUtil.NowUnixMs() - 60001
                });
                Assert(InstanceStateStore.TakePendingCommandEntry(path, 60000) == string.Empty,
                    "An expired command handoff was accepted.");
                Assert(!File.Exists(path), "An expired command handoff was not cleaned up.");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void ChannelIdentityMatchesCrossClientFixture()
        {
            Assert(ServerDatabaseIdentity.FromTokenAndPassword("example-token", "example-password") == "l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU",
                "The existing database identity derivation regressed.");
            Assert(ServerDatabaseIdentity.SyncRulesFromTokenAndPassword("example-token", "example-password") == "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ",
                "The sync rules identity derivation did not match the cross-client fixture.");
            Assert(ServerDatabaseIdentity.ChannelFromTokenAndPassword("example-token", "example-password", "work") == "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA",
                "The \"work\" channel identity derivation did not match the cross-client fixture.");
            Assert(ServerDatabaseIdentity.ChannelFromTokenAndPassword("example-token", "example-password", "desktop only") == "02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o",
                "The \"desktop only\" channel identity derivation did not match the cross-client fixture.");
            Assert(ServerDatabaseIdentity.ChannelFromTokenAndPassword("", "example-password", "work") == string.Empty,
                "A blank server token should yield an empty channel identity.");
            Assert(ServerDatabaseIdentity.ChannelFromTokenAndPassword("example-token", "", "work") == string.Empty,
                "A blank history password should yield an empty channel identity.");
            Assert(ServerDatabaseIdentity.SyncRulesFromTokenAndPassword("", "example-password") == string.Empty,
                "A blank server token should yield an empty sync rules identity.");
            Assert(ServerDatabaseIdentity.SyncRulesFromTokenAndPassword("example-token", "") == string.Empty,
                "A blank history password should yield an empty sync rules identity.");
        }

        // The reduced expectation shape recorded in the fixture corpus
        // (ClipmanCli/testdata/fixtures/README.md). Property names match the
        // JSON keys exactly because JavaScriptSerializer maps them literally.
        private sealed class FixtureViewEntry
        {
            public string id { get; set; }
            public string text { get; set; }
            public string name { get; set; }
            public string group { get; set; }
            public string sourceMachine { get; set; }
            public long createdUnixMs { get; set; }
            public long lastUsedUnixMs { get; set; }
            public bool pinned { get; set; }
            public bool isTemplate { get; set; }
            public long manualOrder { get; set; }
            public bool hasRichText { get; set; }
        }

        private sealed class FixtureExpectedView
        {
            public int version { get; set; }
            public long updatedUnixMs { get; set; }
            public List<FixtureViewEntry> entries { get; set; }
            public List<object> deleted { get; set; }
        }

        private static string FindGoSyncRulesFixtureDirectory()
        {
            var root = Environment.GetEnvironmentVariable("CLIPMAN_REPO_ROOT");
            if (!string.IsNullOrEmpty(root))
            {
                var fromRoot = Path.Combine(Path.Combine(Path.Combine(root, "ClipmanCli"), "testdata"), Path.Combine("fixtures", "go"));
                if (Directory.Exists(fromRoot)) return fromRoot;
            }
            var probe = Environment.CurrentDirectory;
            while (!string.IsNullOrEmpty(probe))
            {
                var candidate = Path.Combine(Path.Combine(Path.Combine(probe, "ClipmanCli"), "testdata"), Path.Combine("fixtures", "go"));
                if (Directory.Exists(candidate)) return candidate;
                probe = Path.GetDirectoryName(probe);
            }
            return null;
        }

        // Task 6.1 of the sync rules plan: decode the blobs the Go reference
        // implementation generated, apply this client's own subscription and
        // merge logic for device Jeff-iPhone (subscribed to the work channel
        // only), and compare the assembled view against expected-view.json.
        // A failure here is a real cross-device sync break, not a style
        // disagreement.
        private static void GoSyncRulesFixtureCorpusDecodesIntoExpectedView()
        {
            var directory = FindGoSyncRulesFixtureDirectory();
            Assert(directory != null,
                "The go-reference sync rules fixture corpus was not found; set CLIPMAN_REPO_ROOT or run from the repository.");

            var password = "example-password";
            var rules = ClipDatabaseFile.Load<SyncRulesDocument>(Path.Combine(directory, "sync-rules.clipdb"), password);
            Assert(rules != null && rules.Clipman == "sync-rules" && rules.Enabled,
                "The rules blob did not decode into an enabled sync-rules document.");
            Assert(SyncRuleEngine.Validate(rules) == null, "The fixture rules document failed validation.");

            var subscribed = SyncRuleEngine.SubscribedChannels(rules, "Jeff-iPhone");
            Assert(subscribed != null && subscribed.Count == 1 && subscribed.Contains("work"),
                "Jeff-iPhone must subscribe to the work channel and nothing else.");

            var core = ClipDatabaseFile.Load(Path.Combine(directory, "core.clipdb"), password);
            var work = ClipDatabaseFile.Load(Path.Combine(directory, "channel-work.clipdb"), password);
            var images = ClipDatabaseFile.Load(Path.Combine(directory, "channel-images.clipdb"), password);
            Assert(core.Entries.Count > 0 && work.Entries.Count > 0 && images.Entries.Count > 0,
                "Every fixture channel blob must decode to at least one entry.");

            // Assemble the subscribed view exactly as the client does: core
            // first, then the subscribed channels in document order, then the
            // dense manual-order renumbering of the merged database.
            var view = new ClipDatabase();
            SyncConflictResolver.MergeInto(view, core);
            SyncConflictResolver.MergeInto(view, work);
            var renumbered = view.Entries
                .OrderBy(e => e.ManualOrder <= 0 ? long.MaxValue : e.ManualOrder)
                .ThenBy(e => e.CreatedUnixMs)
                .ToList();
            for (var index = 0; index < renumbered.Count; index++)
            {
                renumbered[index].ManualOrder = index + 1;
            }

            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var expected = serializer.Deserialize<FixtureExpectedView>(
                File.ReadAllText(Path.Combine(directory, "expected-view.json")));
            Assert(expected != null && expected.entries != null, "expected-view.json did not parse.");

            var actual = view.Entries.OrderBy(e => e.Id, StringComparer.Ordinal).ToList();
            Assert(actual.Count == expected.entries.Count,
                "The assembled view holds " + actual.Count.ToString(CultureInfo.InvariantCulture) +
                " entries, but the fixture expects " + expected.entries.Count.ToString(CultureInfo.InvariantCulture) + ".");
            for (var index = 0; index < actual.Count; index++)
            {
                var got = actual[index];
                var want = expected.entries[index];
                Assert(got.Id == want.id, "View entry " + want.id + " is missing or out of order.");
                Assert(got.Text == want.text, "View entry " + want.id + " text mismatch.");
                Assert((got.Name ?? string.Empty) == want.name, "View entry " + want.id + " name mismatch.");
                Assert((got.Group ?? string.Empty) == want.group, "View entry " + want.id + " group mismatch.");
                Assert((got.SourceMachine ?? string.Empty) == want.sourceMachine, "View entry " + want.id + " source device mismatch.");
                Assert(got.CreatedUnixMs == want.createdUnixMs, "View entry " + want.id + " created timestamp mismatch.");
                Assert(got.LastUsedUnixMs == want.lastUsedUnixMs, "View entry " + want.id + " last-used timestamp mismatch.");
                Assert(got.Pinned == want.pinned, "View entry " + want.id + " pinned mismatch.");
                Assert(got.IsTemplate == want.isTemplate, "View entry " + want.id + " template mismatch.");
                Assert(got.ManualOrder == want.manualOrder, "View entry " + want.id + " manual order mismatch.");
                Assert((got.RichText != null) == want.hasRichText, "View entry " + want.id + " rich text presence mismatch.");
            }
            Assert((view.DeletedEntries == null ? 0 : view.DeletedEntries.Count) == (expected.deleted == null ? 0 : expected.deleted.Count),
                "The assembled view's tombstone count does not match the fixture.");

            // The images channel is unsubscribed: none of its entries may
            // appear in the view.
            foreach (var entry in images.Entries)
            {
                var identifier = entry.Id;
                Assert(!view.Entries.Any(e => string.Equals(e.Id, identifier, StringComparison.OrdinalIgnoreCase)),
                    "An unsubscribed channel's entry leaked into the view.");
            }
        }

        private static void SyncRuleChannelKeyGrammar()
        {
            Assert(SyncRuleEngine.ChannelKey("Work ") == "work", "Trailing whitespace and casing should normalize to the channel key.");
            Assert(SyncRuleEngine.ChannelKey("Desktop Only") == "desktop only", "Internal spaces should be preserved and lowercased.");
            Assert(SyncRuleEngine.ChannelKey("-bad") == string.Empty, "A leading dash should not produce a valid channel key.");
            Assert(SyncRuleEngine.ChannelKey("core") == "core", "A reserved name should still produce a syntactically valid key.");

            var doc = new SyncRulesDocument();
            doc.Channels.Add(new SyncChannel { Name = "core", Route = new SyncRoute { Groups = new List<string> { "Anything" } } });
            var error = SyncRuleEngine.Validate(doc);
            Assert(error != null, "A reserved channel name should be rejected by Validate.");

            var longName = new string('a', 33);
            Assert(SyncRuleEngine.ChannelKey(longName) == string.Empty, "A 33-character channel name should exceed the grammar's length limit.");
            Assert(SyncRuleEngine.ChannelKey("café") == string.Empty, "A non-ASCII channel name should be rejected.");

            // Spaces become dashes in file names, so two keys that differ only there would share
            // one channel file.
            Assert(SyncRuleEngine.ChannelStorageName("my work") == "my-work",
                "The storage name should fold spaces to dashes.");
            var folded = new SyncRulesDocument { Enabled = true };
            folded.Channels.Add(new SyncChannel { Name = "My Work", Route = new SyncRoute { Groups = new List<string> { "A" } } });
            folded.Channels.Add(new SyncChannel { Name = "My-Work", Route = new SyncRoute { Groups = new List<string> { "B" } } });
            Assert(SyncRuleEngine.Validate(folded) != null,
                "Two channel names that fold to the same storage name should be rejected.");
            Assert(SyncRuleEngine.ChannelKey("My Work") != SyncRuleEngine.ChannelKey("My-Work"),
                "The two folded names should still be distinct channel keys.");
        }

        private static void SyncRuleRoutingFirstMatchAndAndSemantics()
        {
            var doc = new SyncRulesDocument { Enabled = true };
            doc.Channels.Add(new SyncChannel { Name = "Images", Route = new SyncRoute { Kind = "RichTextImages" } });
            doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
            doc.Channels.Add(new SyncChannel { Name = "DesktopOnly", Route = new SyncRoute { SourceDevices = new List<string> { "Desktop" } } });

            var imageAndWork = new ClipEntry
            {
                Group = "Work",
                RichText = new RichTextPayload { HtmlFragment = "<img src=\"data:image/png;base64,x\">" }
            };
            Assert(SyncRuleEngine.RouteEntry(doc, imageAndWork) == "images", "The first matching channel in list order should win.");

            var workOnly = new ClipEntry { Group = "work" };
            Assert(SyncRuleEngine.RouteEntry(doc, workOnly) == "work", "Group matching should be case-insensitive.");

            var noMatch = new ClipEntry { Group = "Other", SourceMachine = "Other" };
            Assert(SyncRuleEngine.RouteEntry(doc, noMatch) == string.Empty, "An entry matching no route should route to core.");

            var disabledDoc = new SyncRulesDocument { Enabled = false };
            disabledDoc.Channels.Add(new SyncChannel { Name = "Images", Route = new SyncRoute { Kind = "RichTextImages" } });
            Assert(SyncRuleEngine.RouteEntry(disabledDoc, imageAndWork) == string.Empty, "A disabled rules document should route everything to core.");

            var andDoc = new SyncRulesDocument { Enabled = true };
            andDoc.Channels.Add(new SyncChannel
            {
                Name = "WorkDesktop",
                Route = new SyncRoute { Groups = new List<string> { "Work" }, SourceDevices = new List<string> { "Desktop" } }
            });
            var workFromPhone = new ClipEntry { Group = "Work", SourceMachine = "Phone" };
            Assert(SyncRuleEngine.RouteEntry(andDoc, workFromPhone) == string.Empty,
                "A route with multiple conditions should require every condition to match (AND semantics).");
        }

        private static void SyncRuleSubscriptions()
        {
            var doc = new SyncRulesDocument { Enabled = true };
            doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
            doc.Channels.Add(new SyncChannel { Name = "Images", Route = new SyncRoute { Kind = "RichTextImages" } });
            doc.Devices.Add(new SyncDevice { Name = "Desktop", Channels = new List<string> { "*" } });
            doc.Devices.Add(new SyncDevice { Name = "Jeff-iPhone", Channels = new List<string> { "Work" } });

            Assert(SyncRuleEngine.SubscribedChannels(doc, "Unknown-Device") == null,
                "A device not listed in the rules document should subscribe to everything (null).");

            var everything = SyncRuleEngine.SubscribedChannels(doc, "Desktop");
            Assert(everything != null && everything.Count == 2 && everything.Contains("work") && everything.Contains("images"),
                "A device with \"*\" should subscribe to every channel.");

            var explicitChannels = SyncRuleEngine.SubscribedChannels(doc, " jeff-iphone ");
            Assert(explicitChannels != null && explicitChannels.Count == 1 && explicitChannels.Contains("work"),
                "Device matching should be trimmed and case-insensitive.");
        }

        private static void SyncRulesDocumentJsonRoundTrip()
        {
            var doc = new SyncRulesDocument
            {
                Enabled = true,
                UpdatedUnixMs = 1757200000000,
                UpdatedBy = "Desktop"
            };
            doc.Channels.Add(new SyncChannel { Name = "Images", Route = new SyncRoute { Kind = "RichTextImages" } });
            doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work", "Standup" } } });
            doc.Channels.Add(new SyncChannel { Name = "Desktop only", Route = new SyncRoute { SourceDevices = new List<string> { "Desktop", "Work-PC" } } });
            doc.Devices.Add(new SyncDevice { Name = "Desktop", Channels = new List<string> { "*" } });
            doc.Devices.Add(new SyncDevice { Name = "Jeff-iPhone", Channels = new List<string> { "work" } });
            doc.Devices.Add(new SyncDevice { Name = "Work-PC", Channels = new List<string> { "work", "desktop only" } });

            var json = JsonUtil.SerializePretty(doc);
            var restored = JsonUtil.Deserialize<SyncRulesDocument>(json);

            Assert(restored.Clipman == "sync-rules", "The Clipman marker did not survive a JSON round trip.");
            Assert(restored.Version == 1, "The Version field did not survive a JSON round trip.");
            Assert(restored.Enabled, "The Enabled field did not survive a JSON round trip.");
            Assert(restored.UpdatedUnixMs == 1757200000000, "The UpdatedUnixMs field did not survive a JSON round trip.");
            Assert(restored.UpdatedBy == "Desktop", "The UpdatedBy field did not survive a JSON round trip.");
            Assert(restored.Channels.Count == 3, "Channels did not survive a JSON round trip.");
            Assert(restored.Channels[1].Name == "Work" && restored.Channels[1].Route.Groups.Count == 2,
                "A channel route's Groups did not survive a JSON round trip.");
            Assert(restored.Channels[2].Route.SourceDevices.Count == 2, "A channel route's SourceDevices did not survive a JSON round trip.");
            Assert(restored.Channels[0].Route.Kind == "RichTextImages", "A channel route's Kind did not survive a JSON round trip.");
            Assert(restored.Devices.Count == 3, "Devices did not survive a JSON round trip.");
            Assert(restored.Devices[2].Channels.Count == 2, "A device's Channels list did not survive a JSON round trip.");
        }

        private static void SyncRulesMergeDocumentsLastWriterWins()
        {
            var older = new SyncRulesDocument { UpdatedUnixMs = 1000, UpdatedBy = "Zeta" };
            var newer = new SyncRulesDocument { UpdatedUnixMs = 2000, UpdatedBy = "Alpha" };
            Assert(ReferenceEquals(SyncRuleEngine.MergeDocuments(older, newer), newer),
                "The document with the greater UpdatedUnixMs should win.");
            Assert(ReferenceEquals(SyncRuleEngine.MergeDocuments(newer, older), newer),
                "MergeDocuments should be symmetric on UpdatedUnixMs.");

            var tieLow = new SyncRulesDocument { UpdatedUnixMs = 1000, UpdatedBy = "Alpha" };
            var tieHigh = new SyncRulesDocument { UpdatedUnixMs = 1000, UpdatedBy = "Beta" };
            Assert(ReferenceEquals(SyncRuleEngine.MergeDocuments(tieLow, tieHigh), tieHigh),
                "A tie on UpdatedUnixMs should be broken by the greater UpdatedBy (ordinal).");
            Assert(ReferenceEquals(SyncRuleEngine.MergeDocuments(tieHigh, tieLow), tieHigh),
                "MergeDocuments should be symmetric on the UpdatedBy tiebreak.");

            Assert(ReferenceEquals(SyncRuleEngine.MergeDocuments(null, newer), newer), "A null local document should lose to a non-null remote document.");
            Assert(ReferenceEquals(SyncRuleEngine.MergeDocuments(newer, null), newer), "A null remote document should lose to a non-null local document.");
        }

        private static void SyncRulesLenientParsingAndReadOnlyDocuments()
        {
            var future = new SyncRulesDocument { Version = 2, Enabled = true };
            future.Channels.Add(new SyncChannel { Name = "core", Route = new SyncRoute { Kind = "FutureKind" } });
            Assert(SyncRuleEngine.ReadOnly(future), "A document from a future version should be read-only.");
            Assert(SyncRuleEngine.IsUsable(future), "A future-version document should be applied leniently rather than rejected.");
            Assert(SyncRuleEngine.Validate(future) != null, "Strict validation should still reject a reserved channel name.");

            var current = new SyncRulesDocument { Enabled = true };
            current.Channels.Add(new SyncChannel { Name = "core", Route = new SyncRoute { Groups = new List<string> { "x" } } });
            Assert(!SyncRuleEngine.ReadOnly(current), "A version-1 document should stay editable.");
            Assert(!SyncRuleEngine.IsUsable(current), "A version-1 document must pass strict validation to be usable.");

            var unknownKind = new SyncRulesDocument { Enabled = true };
            unknownKind.Channels.Add(new SyncChannel { Name = "Future", Route = new SyncRoute { Kind = "FutureKind" } });
            unknownKind.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
            Assert(SyncRuleEngine.RouteEntry(unknownKind, new ClipEntry { Group = "Work" }) == "work",
                "An unrecognized route kind must never match, so a later rule still applies.");
            Assert(SyncRuleEngine.RouteEntry(unknownKind, new ClipEntry { Group = "Other" }) == string.Empty,
                "An unrecognized route kind must never match.");

            var alien = new SyncRulesDocument { Clipman = "something-else" };
            Assert(!SyncRuleEngine.IsUsable(alien), "A document with an unrecognized marker must be rejected.");
            Assert(!SyncRuleEngine.IsUsable(null), "A missing document must be rejected.");
        }

        private static string NewRegressionDirectory()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanWindowsRegression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            return directory;
        }

        private static SyncRulesDocument WorkChannelRules(string deviceName)
        {
            var doc = new SyncRulesDocument { Enabled = true };
            doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
            doc.Devices.Add(new SyncDevice { Name = deviceName, Channels = new List<string> { "*" } });
            return doc;
        }

        private static void RulesRouteEntriesIntoChannelFilesOnSave()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var channelPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    store.AddText("Work note", "MoveToTop", 100, 0, "Work");
                    store.AddText("Plain note", "MoveToTop", 100, 0, string.Empty);

                    Assert(File.Exists(channelPath), "A routed entry did not create its channel file.");
                    var channel = ClipDatabaseFile.Load(channelPath, string.Empty);
                    Assert(channel.Entries.Count == 1 && channel.Entries[0].Text == "Work note",
                        "The work channel file did not receive exactly the routed entry.");

                    var core = ClipDatabaseFile.Load(databasePath, string.Empty);
                    Assert(core.Entries.Any(entry => entry.Text == "Plain note"), "The core file lost its unrouted entry.");
                    Assert(!core.Entries.Any(entry => entry.Text == "Work note"), "The core file kept a routed entry.");

                    var view = store.GetEntries();
                    Assert(view.Count(entry => entry.Text == "Work note") == 1,
                        "The merged view did not show the routed entry exactly once.");
                    Assert(view.Count(entry => entry.Text == "Plain note") == 1, "The merged view lost the core entry.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void RulesDisabledKeepsSingleDatabaseFile()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    store.AddText("Plain note", "MoveToTop", 100, 0);
                    store.AddText("Work note", "MoveToTop", 100, 0, "Work");
                    Assert(store.GetSyncRules() == null, "No sync rules document should exist by default.");
                    Assert(store.GetSyncChannelKeys().Count == 0, "No channels should exist without sync rules.");
                    Assert(!store.SyncRulesReadOnly(), "Absent sync rules should not be reported as read-only.");
                    Assert(store.GetEntries().Count == 2, "Disabled sync rules should keep every entry in the single view.");
                }

                var files = Directory.GetFiles(directory).Select(Path.GetFileName).OrderBy(name => name, StringComparer.Ordinal).ToList();
                Assert(files.Count == 1 && files[0] == "clipman-history.clipdb",
                    "Sync rules disabled must leave exactly the legacy history file, found: " + string.Join(", ", files.ToArray()));
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void GroupChangeRelocatesEntryBetweenChannelFiles()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var channelPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    var entry = store.AddText("Movable note", "MoveToTop", 100, 0);
                    Assert(entry != null, "The relocation fixture entry was not created.");
                    Assert(ClipDatabaseFile.Load(databasePath, string.Empty).Entries.Any(item => item.Id == entry.Id),
                        "The fixture entry did not start in the core file.");

                    store.SetGroup(new[] { entry.Id }, "Work");

                    var channel = ClipDatabaseFile.Load(channelPath, string.Empty);
                    Assert(channel.Entries.Any(item => item.Id == entry.Id), "The gaining channel file did not receive the entry.");

                    var core = ClipDatabaseFile.Load(databasePath, string.Empty);
                    Assert(!core.Entries.Any(item => item.Id == entry.Id), "The losing channel file kept the relocated entry.");
                    Assert(core.DeletedEntries.Any(marker =>
                            marker.Id == entry.Id && string.IsNullOrEmpty(marker.TextHash)),
                        "The losing channel file did not receive an empty-TextHash relocation marker.");

                    Assert(store.GetEntries().Count(item => item.Id == entry.Id) == 1,
                        "The view did not show the relocated entry exactly once.");

                    store.Reload();
                    Assert(store.GetEntries().Count(item => item.Id == entry.Id) == 1,
                        "Reloading after a relocation lost or duplicated the entry.");
                    Assert(store.GetEntries().Any(item => item.Id == entry.Id && item.Group == "Work"),
                        "The relocated entry lost the group change that moved it.");

                    // A deletion is filed against the channel the entry actually lived in, or the
                    // channel would resurrect it on the next assembly.
                    store.Delete(entry.Id);
                    var channelAfterDelete = ClipDatabaseFile.Load(channelPath, string.Empty);
                    Assert(channelAfterDelete.DeletedEntries.Any(marker =>
                            marker.Id == entry.Id && !string.IsNullOrEmpty(marker.TextHash)),
                        "Deleting a channel-resident entry did not leave a tombstone in that channel.");
                    Assert(!ClipDatabaseFile.Load(databasePath, string.Empty).DeletedEntries.Any(marker =>
                            marker.Id == entry.Id && !string.IsNullOrEmpty(marker.TextHash)),
                        "A channel entry's deletion tombstone was misfiled into the core channel.");

                    store.Reload();
                    Assert(!store.GetEntries().Any(item => item.Id == entry.Id),
                        "A deleted channel entry came back after a reload.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static string TextHashOf(string text)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(text)))
                    .Replace("-", string.Empty)
                    .ToLowerInvariant();
            }
        }

        private static void CrossChannelTombstonesSuppressOnlyMatchingText()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var channelPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                var rulesPath = Path.Combine(directory, "clipman-sync-rules.clipdb");
                ClipDatabaseFile.SaveAtomic(rulesPath, WorkChannelRules("Desktop"), string.Empty);

                var deletedAt = TimeUtil.NowUnixMs();
                var core = new ClipDatabase();
                core.DeletedEntries.Add(new DeletedClipEntry
                {
                    Id = "deletedelsewhereid",
                    TextHash = TextHashOf("Shared text"),
                    DeletedUnixMs = deletedAt,
                    SourceMachine = "Other"
                });
                core.DeletedEntries.Add(new DeletedClipEntry
                {
                    Id = "relocatedid",
                    TextHash = string.Empty,
                    DeletedUnixMs = deletedAt,
                    SourceMachine = "Other"
                });
                ClipDatabaseFile.SaveAtomic(databasePath, core, string.Empty);

                var work = new ClipDatabase();
                work.Entries.Add(new ClipEntry
                {
                    Id = "suppressedid",
                    Text = "Shared text",
                    Group = "Work",
                    CreatedUnixMs = deletedAt - 1000,
                    LastUsedUnixMs = deletedAt - 1000,
                    ModifiedUnixMs = deletedAt - 1000
                });
                work.Entries.Add(new ClipEntry
                {
                    Id = "relocatedid",
                    Text = "Relocated text",
                    Group = "Work",
                    CreatedUnixMs = deletedAt - 1000,
                    LastUsedUnixMs = deletedAt - 1000,
                    ModifiedUnixMs = deletedAt - 1000
                });
                ClipDatabaseFile.SaveAtomic(channelPath, work, string.Empty);

                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    var view = store.GetEntries();
                    Assert(!view.Any(entry => entry.Id == "suppressedid"),
                        "A non-empty TextHash tombstone did not suppress matching text in another channel.");
                    Assert(view.Any(entry => entry.Id == "relocatedid"),
                        "A relocation marker must never suppress a live entry with the same id in another channel.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void UnsubscribedChannelFileIsNotLoadedIntoView()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var doc = new SyncRulesDocument { Enabled = true };
                doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                doc.Channels.Add(new SyncChannel { Name = "Images", Route = new SyncRoute { Kind = "RichTextImages" } });
                doc.Devices.Add(new SyncDevice { Name = "Limited-PC", Channels = new List<string> { "work" } });

                using (var store = new ClipStore(databasePath, string.Empty, "Limited-PC"))
                {
                    Assert(store.SetSyncRules(doc) == null, "Enabling a restricted subscription should succeed.");
                    store.AddText("Work note", "MoveToTop", 100, 0, "Work");

                    var images = new ClipDatabase();
                    images.Entries.Add(new ClipEntry
                    {
                        Id = "unsubscribedentryid",
                        Text = "Image entry",
                        CreatedUnixMs = TimeUtil.NowUnixMs(),
                        LastUsedUnixMs = TimeUtil.NowUnixMs(),
                        ModifiedUnixMs = TimeUtil.NowUnixMs()
                    });
                    ClipDatabaseFile.SaveAtomic(Path.Combine(directory, "clipman-channel-images.clipdb"), images, string.Empty);

                    store.Reload();
                    Assert(!store.GetEntries().Any(entry => entry.Text == "Image entry"),
                        "An unsubscribed channel file leaked into the merged view.");
                    Assert(store.GetEntries().Any(entry => entry.Text == "Work note"),
                        "A subscribed channel file was dropped from the merged view.");
                    Assert(store.GetSyncChannelKeys().Count == 2,
                        "Channel keys should list every channel in the rules document.");
                    Assert(File.Exists(Path.Combine(directory, "clipman-channel-images.clipdb")),
                        "An unsubscribed channel file must never be removed.");
                    var untouched = ClipDatabaseFile.Load(Path.Combine(directory, "clipman-channel-images.clipdb"), string.Empty);
                    Assert(untouched.Entries.Count == 1, "An unsubscribed channel file must never be rewritten from the view.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void DirtyHashSkipsRewritingUntouchedChannelFiles()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var channelPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    store.AddText("Work note", "MoveToTop", 100, 0, "Work");
                    var plain = store.AddText("Plain note", "MoveToTop", 100, 0);
                    Assert(plain != null, "The core fixture entry was not created.");
                    Assert(File.Exists(channelPath), "The channel file was not created before the dirty-hash check.");

                    var before = File.GetLastWriteTimeUtc(channelPath);
                    System.Threading.Thread.Sleep(60);
                    store.SetName(plain.Id, "Renamed");

                    Assert(File.GetLastWriteTimeUtc(channelPath) == before,
                        "A channel with unchanged content was rewritten by an unrelated save.");
                    Assert(store.LastChannelWriteOrder().Contains(string.Empty),
                        "The core channel should still have been written by the save that changed it.");
                    Assert(!store.LastChannelWriteOrder().Contains("work"),
                        "An unchanged channel must not be committed.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void RelocationWritesTargetFileBeforeSource()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    var entry = store.AddText("Movable note", "MoveToTop", 100, 0);
                    store.SetGroup(new[] { entry.Id }, "Work");

                    var order = store.LastChannelWriteOrder();
                    var target = order.IndexOf("work");
                    var source = order.LastIndexOf(string.Empty);
                    Assert(target >= 0, "The gaining channel was not committed during a relocation.");
                    Assert(source >= 0, "The losing channel was not rewritten during a relocation.");
                    Assert(target < source,
                        "A relocation must commit the gaining channel before the losing channel drops the entry.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void SyncRulesRoundTripThroughStore()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var rulesPath = Path.Combine(directory, "clipman-sync-rules.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    Assert(File.Exists(rulesPath), "The rules document was not persisted beside the history file.");

                    var restored = store.GetSyncRules();
                    Assert(restored != null && restored.Enabled, "The stored rules document did not round trip.");
                    Assert(restored.Channels.Count == 1 && restored.Channels[0].Name == "Work",
                        "The stored rules document lost its channel.");
                    Assert(restored.UpdatedBy == "Desktop", "SetSyncRules should stamp the editing device.");
                    Assert(!ReferenceEquals(restored, store.GetSyncRules()), "GetSyncRules should return a deep copy.");
                    restored.Channels.Clear();
                    Assert(store.GetSyncChannelKeys().Count == 1, "Mutating the returned copy must not affect the store.");
                    Assert(store.GetSyncChannelKeys()[0] == "work", "Channel keys should be normalized.");
                    Assert(!store.SyncRulesReadOnly(), "A version-1 rules document should stay editable.");

                    var reserved = new SyncRulesDocument { Enabled = true };
                    reserved.Channels.Add(new SyncChannel { Name = "core", Route = new SyncRoute { Groups = new List<string> { "x" } } });
                    Assert(store.SetSyncRules(reserved) != null, "A reserved channel name should be rejected by the store.");
                    Assert(store.GetSyncChannelKeys().Count == 1, "A rejected edit must not replace the stored rules.");
                }

                var future = new SyncRulesDocument { Version = 2, Enabled = true };
                future.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                ClipDatabaseFile.SaveAtomic(rulesPath, future, string.Empty);
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SyncRulesReadOnly(), "A future-version rules document must be treated as read-only.");
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) != null,
                        "A read-only rules document must not be rewritten by this client.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void RouteStopsAtUnresolvableFirstMatch()
        {
            // Only a future-version document can carry a channel whose name yields no key, so the
            // case is built at Version 2.
            const string unresolvableName = "Café";
            Assert(SyncRuleEngine.ChannelKey(unresolvableName) == string.Empty,
                "The fixture channel name must be unresolvable or this test proves nothing.");

            var doc = new SyncRulesDocument { Version = 2, Enabled = true };
            doc.Channels.Add(new SyncChannel
            {
                Name = unresolvableName,
                Route = new SyncRoute { Groups = new List<string> { "Work" } }
            });
            doc.Channels.Add(new SyncChannel
            {
                Name = "Work",
                Route = new SyncRoute { Groups = new List<string> { "Work" } }
            });

            Assert(SyncRuleEngine.RouteEntry(doc, new ClipEntry { Group = "Work" }) == string.Empty,
                "Routing must stop at the first matching route and fall to core when its key is unresolvable.");
            Assert(SyncRuleEngine.RouteEntry(doc, new ClipEntry { Group = "Other" }) == string.Empty,
                "An entry matching no route should still live in core.");

            var resolvableFirst = new SyncRulesDocument { Version = 2, Enabled = true };
            resolvableFirst.Channels.Add(new SyncChannel
            {
                Name = "Work",
                Route = new SyncRoute { Groups = new List<string> { "Work" } }
            });
            resolvableFirst.Channels.Add(new SyncChannel
            {
                Name = unresolvableName,
                Route = new SyncRoute { Groups = new List<string> { "Work" } }
            });
            Assert(SyncRuleEngine.RouteEntry(resolvableFirst, new ClipEntry { Group = "Work" }) == "work",
                "A resolvable first match should still win normally.");
        }

        private static void ReadOnlyRulesNeverRelocateResidentEntries()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var workPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                var archivePath = Path.Combine(directory, "clipman-channel-archive.clipdb");
                var rulesPath = Path.Combine(directory, "clipman-sync-rules.clipdb");

                var doc = new SyncRulesDocument { Version = 2, Enabled = true };
                doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                doc.Channels.Add(new SyncChannel { Name = "Archive", Route = new SyncRoute { Groups = new List<string> { "Archive" } } });
                doc.Devices.Add(new SyncDevice { Name = "Desktop", Channels = new List<string> { "*" } });
                ClipDatabaseFile.SaveAtomic(rulesPath, doc, string.Empty);

                // Resident in the work channel but grouped so the rules would route it to archive.
                ClipDatabaseFile.SaveAtomic(
                    workPath,
                    SingleEntryDatabase("residentmisroutedid", "Resident note", "Archive"),
                    string.Empty);

                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SyncRulesReadOnly(), "A version-2 document should be read-only.");
                    Assert(store.GetEntries().Any(entry => entry.Id == "residentmisroutedid"),
                        "The resident fixture entry was not loaded into the view.");

                    var captured = store.AddText("New archive note", "MoveToTop", 100, 0, "Archive");
                    Assert(captured != null, "The new capture was not created.");

                    var work = ClipDatabaseFile.Load(workPath, string.Empty);
                    Assert(work.Entries.Any(entry => entry.Id == "residentmisroutedid"),
                        "A read-only document must leave a resident entry in the channel it already lives in.");
                    Assert(!work.DeletedEntries.Any(marker => marker.Id == "residentmisroutedid"),
                        "A read-only document must not write a relocation marker.");

                    var archive = ClipDatabaseFile.Load(archivePath, string.Empty);
                    Assert(!archive.Entries.Any(entry => entry.Id == "residentmisroutedid"),
                        "A read-only document must not migrate a resident entry to its would-be target.");
                    Assert(archive.Entries.Any(entry => entry.Id == captured.Id),
                        "A new capture must still be routed under a read-only document.");

                    Assert(store.GetEntries().Count(entry => entry.Id == "residentmisroutedid") == 1,
                        "The view lost or duplicated the resident entry.");

                    store.Reload();
                    Assert(store.GetEntries().Count(entry => entry.Id == "residentmisroutedid") == 1,
                        "Reloading under a read-only document lost or duplicated the resident entry.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static ClipDatabase SingleEntryDatabase(string id, string text, string group)
        {
            var now = TimeUtil.NowUnixMs();
            var database = new ClipDatabase();
            database.Entries.Add(new ClipEntry
            {
                Id = id,
                Text = text,
                Group = group,
                CreatedUnixMs = now,
                LastUsedUnixMs = now,
                ModifiedUnixMs = now
            });
            return database;
        }

        private static void ChannelConflictCopiesAreMergedIntoTheChannelFile()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var conflictPath = Path.Combine(directory, "clipman-channel-work-OTHER-PC.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    store.AddText("Work note", "MoveToTop", 100, 0, "Work");

                    ClipDatabaseFile.SaveAtomic(
                        conflictPath,
                        SingleEntryDatabase("conflictcopyentryid", "Conflict copy note", "Work"),
                        string.Empty);

                    store.Reload();

                    Assert(store.GetEntries().Any(entry => entry.Text == "Conflict copy note"),
                        "A channel's cloud conflict copy was not merged into the channel.");
                    Assert(store.GetEntries().Any(entry => entry.Text == "Work note"),
                        "Merging a conflict copy lost the channel's own entry.");
                    Assert(!File.Exists(conflictPath), "A merged channel conflict copy was not removed.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void ChannelFilesAreNeverConsumedAsConflictCopies()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var workPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                var workPcPath = Path.Combine(directory, "clipman-channel-work-pc.clipdb");

                var doc = new SyncRulesDocument { Enabled = true };
                doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                doc.Channels.Add(new SyncChannel { Name = "Work-PC", Route = new SyncRoute { Groups = new List<string> { "WorkPc" } } });
                doc.Devices.Add(new SyncDevice { Name = "Desktop", Channels = new List<string> { "*" } });

                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(doc) == null, "Enabling two similarly named channels should succeed.");

                    ClipDatabaseFile.SaveAtomic(workPath, SingleEntryDatabase("workentryid", "Work channel note", "Work"), string.Empty);
                    ClipDatabaseFile.SaveAtomic(workPcPath, SingleEntryDatabase("workpcentryid", "Work PC channel note", "WorkPc"), string.Empty);

                    store.Reload();

                    Assert(File.Exists(workPath) && File.Exists(workPcPath),
                        "A declared channel file was consumed as another channel's conflict copy.");
                    var view = store.GetEntries();
                    Assert(view.Any(entry => entry.Text == "Work channel note"), "The work channel was lost.");
                    Assert(view.Any(entry => entry.Text == "Work PC channel note"), "The work-pc channel was lost.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void RemovingAChannelRelocatesItsEntries()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var channelPath = Path.Combine(directory, "clipman-channel-work.clipdb");
                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.SetSyncRules(WorkChannelRules("Desktop")) == null, "Enabling sync rules should succeed.");
                    var entry = store.AddText("Work note", "MoveToTop", 100, 0, "Work");
                    Assert(entry != null, "The channel fixture entry was not created.");
                    Assert(ClipDatabaseFile.Load(channelPath, string.Empty).Entries.Any(item => item.Id == entry.Id),
                        "The fixture entry did not start in the work channel.");

                    var withoutWork = new SyncRulesDocument { Enabled = true };
                    withoutWork.Devices.Add(new SyncDevice { Name = "Desktop", Channels = new List<string> { "*" } });
                    Assert(store.SetSyncRules(withoutWork) == null, "Removing a channel should succeed.");

                    Assert(store.GetSyncChannelKeys().Count == 0, "The removed channel is still in the rules document.");
                    Assert(ClipDatabaseFile.Load(databasePath, string.Empty).Entries.Any(item => item.Id == entry.Id),
                        "Removing a channel did not relocate its entry back into the history file.");
                    Assert(!ClipDatabaseFile.Load(channelPath, string.Empty).Entries.Any(item => item.Id == entry.Id),
                        "The removed channel's file kept the entry it should have handed back.");
                    Assert(store.GetEntries().Count(item => item.Id == entry.Id) == 1,
                        "The view lost or duplicated an entry whose channel was removed.");

                    store.Reload();
                    Assert(store.GetEntries().Count(item => item.Id == entry.Id) == 1,
                        "Reloading after a channel removal lost or duplicated the entry.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void RemovingAChannelThisDeviceCannotSeeIsRefused()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var doc = new SyncRulesDocument { Enabled = true };
                doc.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                doc.Channels.Add(new SyncChannel { Name = "Images", Route = new SyncRoute { Kind = "RichTextImages" } });
                doc.Devices.Add(new SyncDevice { Name = "Limited-PC", Channels = new List<string> { "work" } });

                using (var store = new ClipStore(databasePath, string.Empty, "Limited-PC"))
                {
                    Assert(store.SetSyncRules(doc) == null, "Enabling a restricted subscription should succeed.");

                    var withoutImages = new SyncRulesDocument { Enabled = true };
                    withoutImages.Channels.Add(new SyncChannel { Name = "Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                    withoutImages.Devices.Add(new SyncDevice { Name = "Limited-PC", Channels = new List<string> { "work" } });

                    var error = store.SetSyncRules(withoutImages);
                    Assert(error != null, "Removing a channel this device cannot see should be refused.");
                    Assert(error.IndexOf("Images", StringComparison.Ordinal) >= 0,
                        "The refusal message should name the channel this device cannot see: " + error);
                    Assert(error.IndexOf("not subscribed", StringComparison.Ordinal) >= 0,
                        "The refusal message should explain the device is not subscribed: " + error);

                    Assert(store.GetSyncChannelKeys().Count == 2, "The refused edit must not change the rules document.");
                    var unchanged = store.GetSyncRules();
                    Assert(unchanged.Channels.Any(channel => channel.Name == "Images"),
                        "The refused edit removed the channel from the stored document.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void FoldedStorageNameCollisionLoadsButCannotBeSaved()
        {
            var directory = NewRegressionDirectory();
            try
            {
                var databasePath = Path.Combine(directory, "clipman-history.clipdb");
                var rulesPath = Path.Combine(directory, "clipman-sync-rules.clipdb");

                var doc = new SyncRulesDocument { Enabled = true };
                doc.Channels.Add(new SyncChannel { Name = "My Work", Route = new SyncRoute { Groups = new List<string> { "Work" } } });
                doc.Channels.Add(new SyncChannel { Name = "My-Work", Route = new SyncRoute { Groups = new List<string> { "Personal" } } });
                doc.Devices.Add(new SyncDevice { Name = "Desktop", Channels = new List<string> { "*" } });
                ClipDatabaseFile.SaveAtomic(rulesPath, doc, string.Empty);

                Assert(SyncRuleEngine.Validate(doc) != null,
                    "Validate must still reject a folded-storage-name collision on edit.");
                Assert(SyncRuleEngine.IsUsable(doc),
                    "IsUsable must tolerate a folded-storage-name collision already saved to disk.");

                using (var store = new ClipStore(databasePath, string.Empty, "Desktop"))
                {
                    Assert(store.GetSyncChannelKeys().Count == 2,
                        "A previously-saved colliding document should still load with both channels active.");

                    var error = store.SetSyncRules(SyncRuleEngine.Copy(doc));
                    Assert(error != null,
                        "SetSyncRules should refuse to save a new document with a folded-storage-name collision.");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void SyncRuleSummaryTextIsStable()
        {
            var groups = new SyncRoute { Groups = new List<string> { "Work", "Standup" } };
            Assert(SyncRuleEngine.RouteSummary(groups) == "Groups: Work, Standup",
                "Groups routes should summarize as \"Groups: ...\".");

            var images = new SyncRoute { Kind = "RichTextImages" };
            Assert(SyncRuleEngine.RouteSummary(images) == "Images",
                "Rich-text-image routes should summarize as \"Images\".");

            var devices = new SyncRoute { SourceDevices = new List<string> { "Desktop" } };
            Assert(SyncRuleEngine.RouteSummary(devices) == "From: Desktop",
                "Source-device routes should summarize as \"From: ...\".");

            Assert(SyncRuleEngine.SubscriptionSummary(new List<string> { "*" }) == "All channels",
                "A wildcard subscription should summarize as \"All channels\".");
            Assert(SyncRuleEngine.SubscriptionSummary(new List<string> { "work", "images" }) == "work, images",
                "An explicit channel subscription should summarize as a joined list.");
        }

        private static void ServerPollSchedulingIsBounded()
        {
            Assert(ClipStore.CalculateServerPollDelayMilliseconds(1000, 0) == 2000,
                "Healthy server polling should retain the normal two-second interval.");
            Assert(ClipStore.CalculateServerPollDelayMilliseconds(1000, 2500) == 2000,
                "A near-term retry should not create a tight polling loop.");
            Assert(ClipStore.CalculateServerPollDelayMilliseconds(1000, 7000) == 6000,
                "A failed server poll should sleep until its retry backoff expires.");
        }

        private static void UrlLabelsAcceptWindowsPathCharacters()
        {
            var encodedCharacters = new[] { "%22", "%3C", "%3E", "%7C" };
            foreach (var encodedCharacter in encodedCharacters)
            {
                var uri = new Uri("https://example.org/report" + encodedCharacter + "draft.html", UriKind.Absolute);
                var label = LinkPresentation.OfflineLabel(uri);
                Assert(label.Length > 0, "An encoded URL path character prevented an offline label from being generated.");
                Assert(label.IndexOf(".html", StringComparison.OrdinalIgnoreCase) < 0,
                    "A known document extension remained in an offline URL label.");
            }
        }

        private static void RuntimeLogsRotateWithBoundedGenerations()
        {
            var directory = Path.Combine(Path.GetTempPath(), "ClipmanLogRotation-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var path = Path.Combine(directory, "Runtime.log");
                File.WriteAllText(path, "current");
                File.WriteAllText(Path.Combine(directory, "Runtime.1.log"), "first");
                File.WriteAllText(Path.Combine(directory, "Runtime.2.log"), "second");
                File.WriteAllText(Path.Combine(directory, "Runtime.3.log"), "oldest");

                Program.RotateLogFiles(path, 1, 3);

                Assert(!File.Exists(path), "The full active log was not rotated.");
                Assert(File.ReadAllText(Path.Combine(directory, "Runtime.1.log")) == "current",
                    "The active log did not become the newest retained generation.");
                Assert(File.ReadAllText(Path.Combine(directory, "Runtime.2.log")) == "first",
                    "The first retained log generation was not advanced.");
                Assert(File.ReadAllText(Path.Combine(directory, "Runtime.3.log")) == "second",
                    "The oldest retained generation was not bounded correctly.");
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
                    () => string.Empty,
                    () => "Ready. Using local or shared-folder history."))
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
                    var filterPanel = (FlowLayoutPanel)typeof(HistoryForm)
                        .GetField("filterPanel", BindingFlags.Instance | BindingFlags.NonPublic)
                        .GetValue(form);
                    var filterLabel = filterPanel.Controls.OfType<Label>().Single();
                    Assert(filterLabel.Text == "Filter (&G):",
                        "The History filter mnemonic did not agree with its Alt+G command.");
                    var statusText = (ToolStripStatusLabel)typeof(HistoryForm)
                        .GetField("statusText", BindingFlags.Instance | BindingFlags.NonPublic)
                        .GetValue(form);
                    Assert(statusText.Text == "0 clipboard entries. Ready. Using local or shared-folder history.",
                        "The history status did not put the active section count before storage state.");
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
            Assert(
                HistoryForm.BuildNameAndContentText(entries, "\r\n") == "Release notes\r\nhttps://example.com/release\r\nUnnamed text",
                "Name and content copy did not honour the selected separator.");
        }

        private static void MultipleEntrySeparatorsAreConfigurable()
        {
            Assert(new AppSettings().MultipleEntrySeparatorMode == "BlankLine",
                "Multiple-entry copy must retain its conservative blank-line default.");
            Assert(JsonUtil.Deserialize<AppSettings>("{}").MultipleEntrySeparatorMode == "BlankLine",
                "Settings created before the separator preference did not retain the default.");
            Assert(MultipleEntrySeparator.Resolve("None", "ignored") == string.Empty,
                "No separator inserted unexpected text.");
            Assert(MultipleEntrySeparator.Resolve("NewLine", "") == Environment.NewLine,
                "New-line separation was not available.");
            Assert(MultipleEntrySeparator.Resolve("BlankLine", "") == Environment.NewLine + Environment.NewLine,
                "Blank-line separation was not available.");
            Assert(MultipleEntrySeparator.Resolve("Custom", "\\n--\\t") == "\n--\t",
                "Custom multiple-entry separator escapes were not decoded.");
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

        private static void ClipboardNotificationStateRejectsDuplicateWindowsNotifications()
        {
            var state = new ClipboardNotificationState();
            Assert(state.ShouldProcess(1940, false), "The first clipboard sequence was rejected.");
            Assert(!state.ShouldProcess(1940, false),
                "A repeated Windows notification for the same clipboard sequence was processed twice.");
            Assert(state.ShouldProcess(1949, false), "A genuinely new clipboard sequence was rejected.");
            Assert(state.ShouldProcess(1949, true),
                "Flood recovery could not replay the latest suppressed clipboard sequence.");
            Assert(!state.ShouldProcess(1949, false),
                "A notification repeated after flood recovery was processed again.");
            Assert(state.ShouldProcess(0, false),
                "A clipboard event without an available sequence identifier was rejected.");
        }

        private static void ClipboardNotificationsSettleOnNewestSequence()
        {
            var state = new ClipboardNotificationState();
            state.Observe(1941);
            state.Observe(1947);
            state.Observe(1949);
            Assert(state.TakePending() == 1949,
                "A burst of notifications did not settle on its newest clipboard sequence.");
            Assert(state.TakePending() == 0,
                "A settled clipboard notification remained pending for a second capture.");
        }

        private static void ClipboardApplicationCompatibilityIsCentralised()
        {
            Assert(ClipboardApplicationCompatibility.ForProcess("writer").DuplicateNotificationMilliseconds == 60,
                "An ordinary application did not use the conservative duplicate-notification window.");
            Assert(ClipboardApplicationCompatibility.ForProcess("firefox").DuplicateNotificationMilliseconds == 500,
                "Firefox did not receive its known delayed-notification compatibility window.");
            Assert(ClipboardApplicationCompatibility.ForProcess("THUNDERBIRD").DuplicateNotificationMilliseconds == 500,
                "Thunderbird compatibility matching was case-sensitive.");
            Assert(ClipboardApplicationCompatibility.ForProcess("firefox").AcceptChangingSequenceIdentifiers,
                "Firefox did not retain its changing-sequence compatibility rule.");
            Assert(!ClipboardApplicationCompatibility.ForProcess("writer").AcceptChangingSequenceIdentifiers,
                "An ordinary application was allowed to combine different clipboard sequences.");
        }

        private static void ClipboardFloodProtectionIsSourceSpecificAndRecovers()
        {
            var guards = new ClipboardFloodGuardRegistry(4, 2, 100, 50);
            Assert(guards.Observe("noisy", 0) == ClipboardFloodDecision.Allow,
                "A source was suppressed before reaching the configured limit.");
            Assert(guards.Observe("noisy", 10) == ClipboardFloodDecision.Allow,
                "A source was suppressed at the configured limit rather than above it.");
            Assert(guards.Observe("noisy", 20) == ClipboardFloodDecision.SuppressStarted,
                "A rapid third event did not start source-specific suppression.");
            Assert(guards.Observe("quiet", 25) == ClipboardFloodDecision.Allow,
                "One noisy application suppressed an unrelated application.");
            Assert(guards.Observe("noisy", 30) == ClipboardFloodDecision.SuppressContinued,
                "Continued noise was allowed during the quiet period.");
            Assert(guards.ActiveSources(30).SequenceEqual(new[] { "noisy" }),
                "Diagnostics did not report the suppressed source.");
            Assert(guards.ActiveSources(80).Count == 0,
                "A source remained marked as suppressed after the quiet period.");
            Assert(guards.Observe("noisy", 80) == ClipboardFloodDecision.Allow,
                "A source did not recover after its quiet period.");
            Assert(guards.SuppressionCount == 1 && guards.SuppressedEventCount == 2,
                "Registry-level flood diagnostics did not count suppression accurately.");
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

        private static void QuickPasteSnapshotAvoidsOpaqueOleFormats()
        {
            var source = new GuardedClipboardDataObject();
            var snapshot = ClipmanApplicationContext.SnapshotClipboardData(source);

            Assert(snapshot != null, "The safe clipboard formats were not captured.");
            Assert((string)snapshot.GetData(DataFormats.UnicodeText, false) == "safe text",
                "Unicode text was not preserved by the Quick Paste snapshot.");
            Assert((string)snapshot.GetData(DataFormats.Rtf, false) == @"{\rtf1 safe}",
                "Rich Text was not preserved by the Quick Paste snapshot.");
            Assert(!source.UnsafeFormatRead,
                "Quick Paste attempted to materialize an opaque OLE clipboard format.");
            Assert(!source.FormatsEnumerated,
                "Quick Paste enumerated application-owned clipboard formats.");
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

        private sealed class GuardedClipboardDataObject : IDataObject
        {
            public bool UnsafeFormatRead { get; private set; }
            public bool FormatsEnumerated { get; private set; }

            public object GetData(string format, bool autoConvert)
            {
                if (string.Equals(format, DataFormats.EnhancedMetafile, StringComparison.OrdinalIgnoreCase))
                {
                    UnsafeFormatRead = true;
                    throw new InvalidOperationException("Opaque OLE data must not be materialized.");
                }
                if (string.Equals(format, DataFormats.UnicodeText, StringComparison.OrdinalIgnoreCase)) return "safe text";
                if (string.Equals(format, DataFormats.Rtf, StringComparison.OrdinalIgnoreCase)) return @"{\rtf1 safe}";
                return null;
            }

            public object GetData(string format) { return GetData(format, true); }
            public object GetData(Type format) { return null; }

            public bool GetDataPresent(string format, bool autoConvert)
            {
                return string.Equals(format, DataFormats.UnicodeText, StringComparison.OrdinalIgnoreCase) ||
                       string.Equals(format, DataFormats.Rtf, StringComparison.OrdinalIgnoreCase) ||
                       string.Equals(format, DataFormats.EnhancedMetafile, StringComparison.OrdinalIgnoreCase);
            }

            public bool GetDataPresent(string format) { return GetDataPresent(format, true); }
            public bool GetDataPresent(Type format) { return false; }

            public string[] GetFormats(bool autoConvert)
            {
                FormatsEnumerated = true;
                return new[] { DataFormats.UnicodeText, DataFormats.Rtf, DataFormats.EnhancedMetafile };
            }

            public string[] GetFormats() { return GetFormats(true); }
            public void SetData(string format, bool autoConvert, object data) { throw new NotSupportedException(); }
            public void SetData(string format, object data) { throw new NotSupportedException(); }
            public void SetData(Type format, object data) { throw new NotSupportedException(); }
            public void SetData(object data) { throw new NotSupportedException(); }
        }
    }
}
