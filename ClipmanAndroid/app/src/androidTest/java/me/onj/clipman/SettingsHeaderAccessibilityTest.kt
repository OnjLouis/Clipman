package me.onj.clipman

import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsToggleable
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsHeaderAccessibilityTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<SettingsHeaderTestActivity>()

    @Test
    fun settingsActionsExposeStableLabelsAndCombinedRadioChoices() {
        composeRule.onNodeWithContentDescription("Cancel settings")
            .assertIsEnabled()
            .assertHasClickAction()
        composeRule.onNodeWithContentDescription("Save settings")
            .assertIsEnabled()
            .assertHasClickAction()
        composeRule.onNodeWithText("Local")
            .assertIsSelected()
            .assertHasClickAction()
        composeRule.onNodeWithText("Server")
            .assertIsNotSelected()
            .assertHasClickAction()
        composeRule.onNodeWithText("Play sounds")
            .assertIsToggleable()
            .assertIsOn()
            .assertHasClickAction()
    }
}
