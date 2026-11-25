package com.varsys.moneytrail

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationChannelSupportTest {
    @Test
    fun `notification channels are skipped before Android 8`() {
        assertFalse(supportsNotificationChannels(24))
        assertFalse(supportsNotificationChannels(25))
    }

    @Test
    fun `notification channels are supported from Android 8`() {
        assertTrue(supportsNotificationChannels(26))
        assertTrue(supportsNotificationChannels(35))
    }
}
