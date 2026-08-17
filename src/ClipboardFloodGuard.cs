using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace Clipman
{
    internal enum ClipboardFloodDecision
    {
        Allow,
        SuppressStarted,
        SuppressContinued
    }

    internal sealed class ClipboardFloodGuard
    {
        internal const int DefaultMaximumEvents = 12;
        internal const int DefaultWindowMilliseconds = 1000;
        internal const int DefaultQuietMilliseconds = 1500;

        private readonly int maximumEvents;
        private readonly long windowMilliseconds;
        private readonly long quietMilliseconds;
        private readonly Queue<long> recentEvents = new Queue<long>();
        private long lastEventMilliseconds = long.MinValue;
        private bool suppressing;

        internal ClipboardFloodGuard(int maximumEvents, int windowMilliseconds, int quietMilliseconds)
        {
            if (maximumEvents < 1) throw new ArgumentOutOfRangeException("maximumEvents");
            if (windowMilliseconds < 1) throw new ArgumentOutOfRangeException("windowMilliseconds");
            if (quietMilliseconds < 1) throw new ArgumentOutOfRangeException("quietMilliseconds");

            this.maximumEvents = maximumEvents;
            this.windowMilliseconds = windowMilliseconds;
            this.quietMilliseconds = quietMilliseconds;
        }

        internal long LastObservedMilliseconds { get; private set; }

        internal ClipboardFloodDecision Observe(long nowMilliseconds)
        {
            LastObservedMilliseconds = nowMilliseconds;

            if (lastEventMilliseconds != long.MinValue && nowMilliseconds < lastEventMilliseconds)
            {
                recentEvents.Clear();
                suppressing = false;
            }

            if (suppressing)
            {
                if (nowMilliseconds - lastEventMilliseconds < quietMilliseconds)
                {
                    lastEventMilliseconds = nowMilliseconds;
                    return ClipboardFloodDecision.SuppressContinued;
                }

                recentEvents.Clear();
                suppressing = false;
            }

            lastEventMilliseconds = nowMilliseconds;
            while (recentEvents.Count > 0 && nowMilliseconds - recentEvents.Peek() >= windowMilliseconds)
            {
                recentEvents.Dequeue();
            }

            recentEvents.Enqueue(nowMilliseconds);
            if (recentEvents.Count <= maximumEvents)
            {
                return ClipboardFloodDecision.Allow;
            }

            suppressing = true;
            return ClipboardFloodDecision.SuppressStarted;
        }

        internal bool IsSuppressionActive(long nowMilliseconds)
        {
            return suppressing &&
                   lastEventMilliseconds != long.MinValue &&
                   nowMilliseconds >= lastEventMilliseconds &&
                   nowMilliseconds - lastEventMilliseconds < quietMilliseconds;
        }

        internal static long MonotonicMilliseconds()
        {
            return (Stopwatch.GetTimestamp() * 1000L) / Stopwatch.Frequency;
        }
    }

    internal sealed class ClipboardFloodGuardRegistry
    {
        internal const int DefaultCapacity = 64;

        private readonly int capacity;
        private readonly int maximumEvents;
        private readonly int windowMilliseconds;
        private readonly int quietMilliseconds;
        private readonly Dictionary<string, ClipboardFloodGuard> guards =
            new Dictionary<string, ClipboardFloodGuard>(StringComparer.OrdinalIgnoreCase);

        internal ClipboardFloodGuardRegistry()
            : this(DefaultCapacity, ClipboardFloodGuard.DefaultMaximumEvents,
                ClipboardFloodGuard.DefaultWindowMilliseconds, ClipboardFloodGuard.DefaultQuietMilliseconds)
        {
        }

        internal ClipboardFloodGuardRegistry(int capacity, int maximumEvents, int windowMilliseconds, int quietMilliseconds)
        {
            if (capacity < 1) throw new ArgumentOutOfRangeException("capacity");
            this.capacity = capacity;
            this.maximumEvents = maximumEvents;
            this.windowMilliseconds = windowMilliseconds;
            this.quietMilliseconds = quietMilliseconds;
        }

        internal long SuppressionCount { get; private set; }
        internal long SuppressedEventCount { get; private set; }
        internal ClipboardFloodDecision Observe(string source, long nowMilliseconds)
        {
            var key = string.IsNullOrWhiteSpace(source) ? "Unknown application" : source.Trim();
            ClipboardFloodGuard guard;
            if (!guards.TryGetValue(key, out guard))
            {
                if (guards.Count >= capacity)
                {
                    var oldestKey = string.Empty;
                    var oldestTime = long.MaxValue;
                    foreach (var pair in guards)
                    {
                        if (pair.Value.LastObservedMilliseconds >= oldestTime) continue;
                        oldestKey = pair.Key;
                        oldestTime = pair.Value.LastObservedMilliseconds;
                    }
                    if (oldestKey.Length > 0) guards.Remove(oldestKey);
                }

                guard = new ClipboardFloodGuard(maximumEvents, windowMilliseconds, quietMilliseconds);
                guards[key] = guard;
            }

            var decision = guard.Observe(nowMilliseconds);
            if (decision == ClipboardFloodDecision.SuppressStarted) SuppressionCount++;
            if (decision != ClipboardFloodDecision.Allow) SuppressedEventCount++;
            return decision;
        }

        internal List<string> ActiveSources(long nowMilliseconds)
        {
            var active = new List<string>();
            foreach (var pair in guards)
            {
                if (pair.Value.IsSuppressionActive(nowMilliseconds)) active.Add(pair.Key);
            }
            return active;
        }
    }
}
