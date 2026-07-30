package com.example.casein_mob

import org.junit.Assert.assertEquals
import org.junit.Test

class MobButtonActivationTest {
    @Test
    fun `disabled button never dispatches its tap handle`() {
        val dispatched = mutableListOf<Int>()

        MobButtonActivation(enabled = false, tapHandle = 42).dispatch(dispatched::add)

        assertEquals(emptyList<Int>(), dispatched)
    }

    @Test
    fun `enabled button dispatches its tap handle exactly once`() {
        val dispatched = mutableListOf<Int>()

        MobButtonActivation(enabled = true, tapHandle = 42).dispatch(dispatched::add)

        assertEquals(listOf(42), dispatched)
    }

    @Test
    fun `enabled button without a registered handle is inert`() {
        val dispatched = mutableListOf<Int>()

        MobButtonActivation(enabled = true, tapHandle = null).dispatch(dispatched::add)

        assertEquals(emptyList<Int>(), dispatched)
    }
}
