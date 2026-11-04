package com.mattmacosko.realtimeaicam.translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ObjectLabelTranslationsTest {
    private val labels = File("src/main/assets/class_names.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() }

    @Test fun everyContextKeyIsARealLabel() {
        val set = labels.toSet()
        val missing = ObjectLabelTranslations.CONTEXT.keys.filter { it !in set }
        assertTrue("not in class_names.txt: $missing", missing.isEmpty())
    }

    @Test fun ambiguousLabelsGetContext() {
        assertEquals("mouse (animal)", ObjectLabelTranslations.sourcePhrase("Mouse"))
        assertEquals("computer mouse", ObjectLabelTranslations.sourcePhrase("Computer mouse"))
        assertEquals("bat (flying animal)", ObjectLabelTranslations.sourcePhrase("Bat (Animal)"))
        assertEquals("baseball bat", ObjectLabelTranslations.sourcePhrase("Baseball bat"))
        assertEquals("eyeglasses", ObjectLabelTranslations.sourcePhrase("Glasses"))
        assertEquals("wine glass", ObjectLabelTranslations.sourcePhrase("Wine glass"))
        assertEquals("stool (seat)", ObjectLabelTranslations.sourcePhrase("Stool"))
        assertEquals("necktie", ObjectLabelTranslations.sourcePhrase("Tie"))
        assertEquals("ruler (measuring tool)", ObjectLabelTranslations.sourcePhrase("Ruler"))
        // Plain labels are just lower-cased.
        assertEquals("zebra", ObjectLabelTranslations.sourcePhrase("Zebra"))
    }

    @Test fun bracketNotesAreDroppedFromAnswers() {
        assertEquals("ratón", ObjectLabelTranslations.cleanOutput("ratón (animal)"))
        assertEquals("murciélago", ObjectLabelTranslations.cleanOutput(" murciélago  (animal volador) "))
        assertEquals("taburete", ObjectLabelTranslations.cleanOutput("taburete [asiento]"))
        assertEquals("鼠标", ObjectLabelTranslations.cleanOutput("鼠标（电脑）"))
        assertEquals("souris d'ordinateur", ObjectLabelTranslations.cleanOutput("souris d'ordinateur"))
    }

    @Test fun serializeParseRoundTrip() {
        val names = listOf("ratón", "dice \"hola\"", "back\\slash", "línea\nnueva", "Ж")
        val json = ObjectLabelTranslations.serialize("es", "abc", names)
        assertEquals(names, ObjectLabelTranslations.parse(json, "es", "abc", names.size))
        assertNull(ObjectLabelTranslations.parse(json, "fr", "abc", names.size)) // other language
        assertNull(ObjectLabelTranslations.parse(json, "es", "xyz", names.size)) // other list
        assertNull(ObjectLabelTranslations.parse(json, "es", "abc", names.size + 1)) // wrong count
        assertNull(ObjectLabelTranslations.parse("{\"lang\":\"es\",\"signa", "es", "abc", 1)) // damaged
    }

    @Test fun builtOnceThenReadFromTheFile() {
        val dir = Files.createTempDirectory("labels").toFile()
        var calls = 0
        val fake = { s: String -> calls++; "es:$s" }
        val first = ObjectLabelTranslations.loadOrBuild(dir, "es", labels, fake)!!
        assertEquals(labels.size, calls)
        assertEquals(labels.size, first.size)
        assertEquals("es:mouse", first[labels.indexOf("Mouse")]) // "(animal)" note dropped
        assertEquals("es:computer mouse", first[labels.indexOf("Computer mouse")])
        assertTrue(ObjectLabelTranslations.cacheFile(dir, "es").exists())
        val second = ObjectLabelTranslations.loadOrBuild(dir, "es", labels, fake)!!
        assertEquals(labels.size, calls) // no translating the second time
        assertEquals(first, second)
        dir.deleteRecursively()
    }

    @Test fun changedListRebuilds() {
        val dir = Files.createTempDirectory("labels").toFile()
        val small = listOf("Mouse", "Zebra")
        ObjectLabelTranslations.loadOrBuild(dir, "fr", small) { "fr:$it" }
        val changed = listOf("Mouse", "Zebra", "Cup")
        assertNotEquals(ObjectLabelTranslations.signature(small), ObjectLabelTranslations.signature(changed))
        assertNull(ObjectLabelTranslations.load(dir, "fr", changed))
        var calls = 0
        val rebuilt = ObjectLabelTranslations.loadOrBuild(dir, "fr", changed) { calls++; "fr2:$it" }!!
        assertEquals(3, calls)
        assertEquals(listOf("fr2:mouse", "fr2:zebra", "fr2:cup"), rebuilt)
        dir.deleteRecursively()
    }

    @Test fun halfBuiltListIsNeverSaved() {
        val dir = Files.createTempDirectory("labels").toFile()
        val out = ObjectLabelTranslations.loadOrBuild(dir, "de", listOf("Mouse", "Zebra")) { if (it == "zebra") null else "x" }
        assertNull(out)
        assertTrue(!ObjectLabelTranslations.cacheFile(dir, "de").exists())
        dir.deleteRecursively()
    }

    @Test fun eachLanguageHasItsOwnFile() {
        val dir = Files.createTempDirectory("labels").toFile()
        ObjectLabelTranslations.loadOrBuild(dir, "es", listOf("Mouse")) { "ratón" }
        ObjectLabelTranslations.loadOrBuild(dir, "fr", listOf("Mouse")) { "souris" }
        assertEquals(listOf("ratón"), ObjectLabelTranslations.load(dir, "es", listOf("Mouse")))
        assertEquals(listOf("souris"), ObjectLabelTranslations.load(dir, "fr", listOf("Mouse")))
        dir.deleteRecursively()
    }
}
