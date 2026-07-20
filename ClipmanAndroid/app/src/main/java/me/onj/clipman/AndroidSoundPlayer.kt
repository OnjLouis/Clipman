package me.onj.clipman

import android.content.Context
import android.media.MediaPlayer

enum class ClipmanSound {
    Copy,
    Exclude,
    Off,
    On,
    Remote,
    Skip
}

object AndroidSoundPlayer {
    private var currentPlayer: MediaPlayer? = null

    fun play(context: Context, sound: ClipmanSound) {
        val resId = when (sound) {
            ClipmanSound.Copy -> R.raw.copy
            ClipmanSound.Exclude -> R.raw.exclude
            ClipmanSound.Off -> R.raw.off
            ClipmanSound.On -> R.raw.on
            ClipmanSound.Remote -> R.raw.remote
            ClipmanSound.Skip -> R.raw.skip
        }
        runCatching {
            currentPlayer?.let { player ->
                runCatching {
                    if (player.isPlaying) player.stop()
                }
                runCatching {
                    player.release()
                }
            }
            currentPlayer = null
            MediaPlayer.create(context.applicationContext, resId)?.apply {
                currentPlayer = this
                setOnCompletionListener { player ->
                    if (currentPlayer === player) currentPlayer = null
                    player.release()
                }
                start()
            }
        }
    }
}
