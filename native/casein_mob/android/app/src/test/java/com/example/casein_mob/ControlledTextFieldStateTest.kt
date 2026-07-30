package com.example.casein_mob

import org.junit.Assert.assertEquals
import org.junit.Test

class ControlledTextFieldStateTest {
    @Test
    fun `focused sequential input ignores stale parent echoes`() {
        val state = ControlledTextFieldState("")
        state.onFocusChanged(true)

        var previous = ""
        "Yes, continue.".forEach { character ->
            val next = state.value + character
            state.onLocalValue(next)
            state.onExternalValue(previous)
            previous = next
        }

        assertEquals("Yes, continue.", state.value)

        state.onExternalValue(previous)
        assertEquals("Yes, continue.", state.value)
    }

    @Test
    fun `focused atomic accessibility input survives an older parent value`() {
        val state = ControlledTextFieldState("")
        state.onFocusChanged(true)

        state.onLocalValue("Yes, continue.")
        state.onExternalValue("")

        assertEquals("Yes, continue.", state.value)
    }

    @Test
    fun `focused field accepts a programmatic parent replacement`() {
        val state = ControlledTextFieldState("old code")
        state.onFocusChanged(true)

        state.onExternalValue("fresh clipboard code")

        assertEquals("fresh clipboard code", state.value)
    }

    @Test
    fun `unfocused field follows an external parent value`() {
        val state = ControlledTextFieldState("draft")

        state.onExternalValue("restored")

        assertEquals("restored", state.value)
    }

    @Test
    fun `blur reconciles the latest external parent value`() {
        val state = ControlledTextFieldState("server")
        state.onFocusChanged(true)
        state.onLocalValue("local")
        state.onExternalValue("authoritative")

        state.onFocusChanged(false)

        assertEquals("authoritative", state.value)
    }

    @Test
    fun `submitted field accepts reset after a delayed local echo`() {
        val state = ControlledTextFieldState("")
        state.onFocusChanged(true)
        state.onLocalValue("Yes")

        state.onSubmit()
        state.onExternalValue("Yes")
        state.onExternalValue("")

        assertEquals("", state.value)
    }
}
