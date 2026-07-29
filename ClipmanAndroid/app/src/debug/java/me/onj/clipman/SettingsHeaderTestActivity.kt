package me.onj.clipman

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme

class SettingsHeaderTestActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Column {
                    SettingsHeader(isSaving = false, onCancel = {}, onSave = {})
                    StorageModeSelector(
                        storageMode = MobileStorageMode.Local,
                        enabled = true,
                        onStorageModeChanged = {},
                    )
                    SettingCheckboxRow(
                        checked = true,
                        onCheckedChange = {},
                        label = "Play sounds"
                    )
                }
            }
        }
    }
}
