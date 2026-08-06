using System;
using System.Collections.Generic;
using System.IO;

namespace Clipman
{
    internal enum ClipMergeKind
    {
        Text,
        Files
    }

    internal sealed class ClipMergeObservation
    {
        public ClipMergeKind Kind { get; set; }
        public string Signature { get; set; }
        public string SourceApplication { get; set; }
        public string Operation { get; set; }
        public string HistoryId { get; set; }
        public uint ChangeIdentifier { get; set; }
        public object Payload { get; set; }

        public ClipMergeObservation()
        {
            Signature = string.Empty;
            SourceApplication = string.Empty;
            Operation = string.Empty;
            HistoryId = string.Empty;
        }
    }

    internal sealed class ClipMergeDecision
    {
        public bool ShouldMerge { get; private set; }
        public bool SuppressDuplicate { get; private set; }
        public ClipMergeObservation Base { get; private set; }
        public ClipMergeObservation FirstTap { get; private set; }

        private ClipMergeDecision()
        {
        }

        public static ClipMergeDecision Replace()
        {
            return new ClipMergeDecision();
        }

        public static ClipMergeDecision Merge(ClipMergeObservation baseItem, ClipMergeObservation firstTap)
        {
            return new ClipMergeDecision
            {
                ShouldMerge = true,
                Base = baseItem,
                FirstTap = firstTap
            };
        }

        public static ClipMergeDecision Duplicate()
        {
            return new ClipMergeDecision { SuppressDuplicate = true };
        }
    }

    internal sealed class ClipMergeDetector
    {
        public const int DefaultWindowMilliseconds = 500;
        public const int MinimumWindowMilliseconds = 200;
        public const int MaximumWindowMilliseconds = 2000;
        public const int DuplicateNotificationMilliseconds = 60;
        public const int MozillaDuplicateNotificationMilliseconds = 500;

        private ClipMergeObservation current;
        private ClipMergeObservation candidateBase;
        private ClipMergeObservation candidateFirstTap;
        private long candidateStartedMilliseconds;

        public ClipMergeDecision Observe(ClipMergeObservation incoming, long nowMilliseconds, bool enabled, int windowMilliseconds, bool deliberate)
        {
            if (incoming == null) throw new ArgumentNullException("incoming");
            windowMilliseconds = NormalizeWindow(windowMilliseconds);

            if (!enabled || deliberate || string.IsNullOrWhiteSpace(incoming.SourceApplication))
            {
                candidateBase = null;
                candidateFirstTap = null;
                current = incoming;
                return ClipMergeDecision.Replace();
            }

            var elapsed = nowMilliseconds - candidateStartedMilliseconds;
            if (candidateFirstTap != null && SameTap(candidateFirstTap, incoming) &&
                IsDuplicateNotification(candidateFirstTap, incoming, elapsed))
            {
                candidateStartedMilliseconds = nowMilliseconds;
                return ClipMergeDecision.Duplicate();
            }
            if (candidateFirstTap != null && candidateBase != null && elapsed >= 0 && elapsed <= windowMilliseconds &&
                SameTap(candidateFirstTap, incoming) && Compatible(candidateBase, incoming))
            {
                var decision = ClipMergeDecision.Merge(candidateBase, candidateFirstTap);
                candidateBase = null;
                candidateFirstTap = null;
                return decision;
            }

            candidateBase = current;
            candidateFirstTap = incoming;
            candidateStartedMilliseconds = nowMilliseconds;
            current = incoming;
            return ClipMergeDecision.Replace();
        }

        public void SetCurrentHistoryId(string historyId)
        {
            if (current != null) current.HistoryId = historyId ?? string.Empty;
            if (candidateFirstTap != null && ReferenceEquals(current, candidateFirstTap))
            {
                candidateFirstTap.HistoryId = historyId ?? string.Empty;
            }
        }

        public void CompleteMerge(ClipMergeObservation merged, string historyId)
        {
            if (merged == null) throw new ArgumentNullException("merged");
            merged.HistoryId = historyId ?? string.Empty;
            current = merged;
            candidateBase = null;
            candidateFirstTap = null;
        }

        public void RetainFirstTap(ClipMergeObservation firstTap)
        {
            current = firstTap;
            candidateBase = null;
            candidateFirstTap = null;
        }

        public void Reset()
        {
            current = null;
            candidateBase = null;
            candidateFirstTap = null;
            candidateStartedMilliseconds = 0;
        }

        public static int NormalizeWindow(int value)
        {
            return Math.Max(MinimumWindowMilliseconds, Math.Min(MaximumWindowMilliseconds, value));
        }

        public static string ResolveSeparator(string mode, string custom)
        {
            switch ((mode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "BLANKLINE": return Environment.NewLine + Environment.NewLine;
                case "SPACE": return " ";
                case "COMMASPACE": return ", ";
                case "CUSTOM": return DecodeCustomSeparator(custom);
                case "NEWLINE":
                default: return Environment.NewLine;
            }
        }

        private static string DecodeCustomSeparator(string value)
        {
            return (value ?? string.Empty)
                .Replace("\\r\\n", "\r\n")
                .Replace("\\n", "\n")
                .Replace("\\r", "\r")
                .Replace("\\t", "\t");
        }

        private static bool SameTap(ClipMergeObservation left, ClipMergeObservation right)
        {
            return left.Kind == right.Kind &&
                string.Equals(left.Signature, right.Signature, StringComparison.Ordinal) &&
                string.Equals(left.SourceApplication, right.SourceApplication, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(left.Operation, right.Operation, StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsDuplicateNotification(ClipMergeObservation left, ClipMergeObservation right, long elapsedMilliseconds)
        {
            if (left.ChangeIdentifier != 0 && right.ChangeIdentifier != 0)
            {
                if (left.ChangeIdentifier == right.ChangeIdentifier) return true;
                return IsMozillaApplication(left.SourceApplication) && elapsedMilliseconds >= 0 &&
                    elapsedMilliseconds < MozillaDuplicateNotificationMilliseconds;
            }
            var threshold = IsMozillaApplication(left.SourceApplication)
                ? MozillaDuplicateNotificationMilliseconds
                : DuplicateNotificationMilliseconds;
            return elapsedMilliseconds >= 0 && elapsedMilliseconds < threshold;
        }

        private static bool IsMozillaApplication(string value)
        {
            var source = value ?? string.Empty;
            return source.IndexOf("firefox", StringComparison.OrdinalIgnoreCase) >= 0 ||
                source.IndexOf("thunderbird", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool Compatible(ClipMergeObservation baseItem, ClipMergeObservation incoming)
        {
            return baseItem.Kind == incoming.Kind &&
                !string.Equals(baseItem.Signature, incoming.Signature, StringComparison.Ordinal) &&
                (incoming.Kind != ClipMergeKind.Files ||
                 string.Equals(baseItem.Operation, incoming.Operation, StringComparison.OrdinalIgnoreCase));
        }
    }

    internal static class ClipMergeFilePolicy
    {
        public static bool AreSourcesAvailable(IEnumerable<string> paths)
        {
            if (paths == null) return false;
            var found = false;
            foreach (var value in paths)
            {
                var path = (value ?? string.Empty).Trim();
                if (path.Length == 0) return false;
                found = true;
                if (!File.Exists(path) && !Directory.Exists(path)) return false;
            }
            return found;
        }
    }
}
