using System;

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
    }

    internal sealed class ClipMergeDetector
    {
        public const int DefaultWindowMilliseconds = 500;
        public const int MinimumWindowMilliseconds = 200;
        public const int MaximumWindowMilliseconds = 2000;

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

        private static bool Compatible(ClipMergeObservation baseItem, ClipMergeObservation incoming)
        {
            return baseItem.Kind == incoming.Kind &&
                (incoming.Kind != ClipMergeKind.Files ||
                 string.Equals(baseItem.Operation, incoming.Operation, StringComparison.OrdinalIgnoreCase));
        }
    }
}
