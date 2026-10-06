package com.openmausbot.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SignedOutEngineTest {
    @Test
    fun directAndRoomFailuresUseTheirSpeakerAndOnlySignInEngines() {
        val bot = Bot("b", "direct", "Bot", "", "", true, "green", false, ModelSelection("claude", "m"), 1.0)
        val room = Room("r", "room", "Room", listOf("b"), GroupResponder("bot", "b"), "", false, 1.0)
        val state = CompanionState(bots = listOf(bot), rooms = listOf(room))
        val engine = Instance("claude", "claudeAgent", "Claude", ProviderSnapshot("available", authenticated = false),
            install = InstanceInstall(), models = ModelCatalog("m", emptyList()))
        val failed = Message("e", Message.Role.BOT, Message.Kind.ACTIVITY, 2.0,
            tool = ToolActivity("error: Not logged in · Please run /login", ok = false, setup = true),
            from = Sender("b", "Bot", "green"))

        assertEquals(engine, signedOutEngine(Chat.BotChat(bot), failed, state, listOf(engine)))
        assertEquals(engine, signedOutEngine(Chat.RoomChat(room), failed, state, listOf(engine)))
        assertNull(signedOutEngine(Chat.RoomChat(room), failed.copy(from = null), state, listOf(engine)))
        assertNull(signedOutEngine(Chat.BotChat(bot), failed.copy(tool = failed.tool!!.copy(setup = false)), state, listOf(engine)))
        assertNull(signedOutEngine(Chat.BotChat(bot), failed.copy(tool = failed.tool!!.copy(claudeUpdate = true)), state, listOf(engine)))
        assertNull(signedOutEngine(Chat.BotChat(bot), failed, state, listOf(engine.copy(snapshot = ProviderSnapshot("available", authenticated = true)))))
        assertNull(signedOutEngine(Chat.BotChat(bot), failed, state, listOf(engine.copy(access = "api", driverKind = "openai-compat"))))
        assertNull(signedOutEngine(Chat.BotChat(bot), failed, state, listOf(engine.copy(install = InstanceInstall("connections")))))
    }
}
