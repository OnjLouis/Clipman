using System;
using System.IO;
using System.Media;
using System.Threading;

namespace Clipman
{
    internal sealed class SoundService
    {
        private readonly string soundDirectory;
        private readonly string userSoundDirectory;
        private readonly object sync = new object();
        private SoundPlayer currentPlayer;
        private Stream currentStream;

        public SoundService(string appDirectory, string settingsDirectory)
        {
            soundDirectory = Path.Combine(appDirectory, "sounds");
            userSoundDirectory = string.IsNullOrWhiteSpace(settingsDirectory)
                ? string.Empty
                : Path.Combine(settingsDirectory, "sounds");
        }

        public void Copy(bool enabled) { Play("copy.wav", enabled); }
        public void On(bool enabled) { Play("on.wav", enabled); }
        public void Off(bool enabled) { Play("off.wav", enabled); }
        public void Remote(bool enabled) { Play("remote.wav", enabled); }
        public void Skip(bool enabled) { Play("skip.wav", enabled); }
        public void Exclude(bool enabled) { Play("exclude.wav", enabled, "skip.wav"); }

        private void Play(string fileName, bool enabled)
        {
            Play(fileName, enabled, string.Empty);
        }

        private void Play(string fileName, bool enabled, string fallbackFileName)
        {
            if (!enabled) return;
            var path = PreferredSoundPath(fileName);
            if (!File.Exists(path) && !string.IsNullOrWhiteSpace(fallbackFileName))
            {
                path = PreferredSoundPath(fallbackFileName);
            }
            if (!File.Exists(path)) return;
            try
            {
                var data = File.ReadAllBytes(path);
                lock (sync)
                {
                    if (currentPlayer != null)
                    {
                        try { currentPlayer.Stop(); } catch { }
                        try { currentPlayer.Dispose(); } catch { }
                        currentPlayer = null;
                    }
                    if (currentStream != null)
                    {
                        try { currentStream.Dispose(); } catch { }
                        currentStream = null;
                    }

                    currentStream = new MemoryStream(data);
                    currentPlayer = new SoundPlayer(currentStream);
                    currentPlayer.Play();
                }
            }
            catch
            {
            }
        }

        private string PreferredSoundPath(string fileName)
        {
            if (!string.IsNullOrWhiteSpace(userSoundDirectory))
            {
                var userPath = Path.Combine(userSoundDirectory, fileName);
                if (File.Exists(userPath)) return userPath;
            }

            return Path.Combine(soundDirectory, fileName);
        }
    }
}
