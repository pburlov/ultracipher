package burlov.ultracipher.swing;

import java.awt.event.KeyEvent;
import java.awt.event.KeyListener;
import java.util.LinkedHashMap;
import java.util.Map;

import javax.swing.text.AbstractDocument;
import javax.swing.text.AttributeSet;
import javax.swing.text.BadLocationException;
import javax.swing.text.DocumentFilter;
import javax.swing.text.JTextComponent;

public class Translator extends DocumentFilter implements KeyListener {
    public static final Map<String, String> ELDER_FUTHARK_CHAR_MAPPING = new LinkedHashMap<String, String>();
    public static final Map<String, String> ELDER_FUTHARK_SYMBOL_GROUP_MAPPING = new LinkedHashMap<String, String>();
    public static final Map<String, String> ANGLO_SAXON_CHAR_MAPPING = new LinkedHashMap<String, String>();
    public static final Map<String, String> ANGLO_SAXON_SYMBOL_GROUP_MAPPING = new LinkedHashMap<String, String>();

    static {
        ELDER_FUTHARK_SYMBOL_GROUP_MAPPING.put("ᛏᚺ", "ᚦ");// TH
        ELDER_FUTHARK_SYMBOL_GROUP_MAPPING.put("ᚨᛖ", "ᛇ");// AE
        ELDER_FUTHARK_SYMBOL_GROUP_MAPPING.put("ᚾᚷ", "ᛜ");// NG
        ELDER_FUTHARK_CHAR_MAPPING.put("F", "ᚠ");
        ELDER_FUTHARK_CHAR_MAPPING.put("V", "ᚠ");// Ersatz
        ELDER_FUTHARK_CHAR_MAPPING.put("U", "ᚢ");
        ELDER_FUTHARK_CHAR_MAPPING.put("A", "ᚨ");
        ELDER_FUTHARK_CHAR_MAPPING.put("R", "ᚱ");
        ELDER_FUTHARK_CHAR_MAPPING.put("K", "ᚲ");
        ELDER_FUTHARK_CHAR_MAPPING.put("C", "ᚲ");
        ELDER_FUTHARK_CHAR_MAPPING.put("Q", "ᚲ");
        ELDER_FUTHARK_CHAR_MAPPING.put("G", "ᚷ");
        ELDER_FUTHARK_CHAR_MAPPING.put("W", "ᚹ");
        ELDER_FUTHARK_CHAR_MAPPING.put("H", "ᚺ");
        ELDER_FUTHARK_CHAR_MAPPING.put("N", "ᚾ");
        ELDER_FUTHARK_CHAR_MAPPING.put("I", "ᛁ");
        ELDER_FUTHARK_CHAR_MAPPING.put("J", "ᛃ");
        ELDER_FUTHARK_CHAR_MAPPING.put("P", "ᛈ");
        ELDER_FUTHARK_CHAR_MAPPING.put("Z", "ᛉ");
        ELDER_FUTHARK_CHAR_MAPPING.put("S", "ᛊ");
        ELDER_FUTHARK_CHAR_MAPPING.put("T", "ᛏ");
        ELDER_FUTHARK_CHAR_MAPPING.put("B", "ᛒ");
        ELDER_FUTHARK_CHAR_MAPPING.put("E", "ᛖ");
        ELDER_FUTHARK_CHAR_MAPPING.put("M", "ᛗ");
        ELDER_FUTHARK_CHAR_MAPPING.put("L", "ᛚ");
        ELDER_FUTHARK_CHAR_MAPPING.put("O", "ᛟ");
        ELDER_FUTHARK_CHAR_MAPPING.put("D", "ᛞ");
        ELDER_FUTHARK_CHAR_MAPPING.put("Y", "\u16E6");

        // http://en.wikipedia.org/wiki/Anglo-Saxon_runes
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛏᚻ", "ᚦ");// TH
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛁᚾᚸ", "ᛝ");// ING
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛖᚩ", "ᛇ");// EO
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᚩᛖ", "ᛟ");// OE
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛖᚪ", "ᛠ");// EA
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᚪᛖ", "ᚫ");// AE
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛁᚪ", "ᛡ");// IA
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛁᚩ", "ᛡ");// IO
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛋᛏ", "ᛥ");// ST
        ANGLO_SAXON_SYMBOL_GROUP_MAPPING.put("ᛣᚹ", "ᛢ");// KW
        ANGLO_SAXON_CHAR_MAPPING.put("F", "ᚠ");
        ANGLO_SAXON_CHAR_MAPPING.put("V", "ᚠ");// Ersatz
        ANGLO_SAXON_CHAR_MAPPING.put("U", "ᚢ");
        ANGLO_SAXON_CHAR_MAPPING.put("O", "ᚩ");
        ANGLO_SAXON_CHAR_MAPPING.put("R", "ᚱ");
        ANGLO_SAXON_CHAR_MAPPING.put("C", "ᚳ");
        // ANGLO_SAXON.put("G", "ᚷ");//http://en.wikipedia.org/wiki/Gyfu
        ANGLO_SAXON_CHAR_MAPPING.put("G", "ᚸ");// http://en.wikipedia.org/wiki/Gar_(rune)#Anglo-Saxon_gar_rune
        ANGLO_SAXON_CHAR_MAPPING.put("W", "ᚹ");
        ANGLO_SAXON_CHAR_MAPPING.put("H", "ᚻ");
        ANGLO_SAXON_CHAR_MAPPING.put("N", "ᚾ");
        ANGLO_SAXON_CHAR_MAPPING.put("I", "ᛁ");
        ANGLO_SAXON_CHAR_MAPPING.put("J", "ᛄ");
        ANGLO_SAXON_CHAR_MAPPING.put("P", "ᛈ");
        ANGLO_SAXON_CHAR_MAPPING.put("X", "ᛉ");
        ANGLO_SAXON_CHAR_MAPPING.put("Z", "ᛋ");// Ersatz
        ANGLO_SAXON_CHAR_MAPPING.put("S", "ᛋ");
        ANGLO_SAXON_CHAR_MAPPING.put("T", "ᛏ");
        ANGLO_SAXON_CHAR_MAPPING.put("B", "ᛒ");
        ANGLO_SAXON_CHAR_MAPPING.put("E", "ᛖ");
        ANGLO_SAXON_CHAR_MAPPING.put("M", "ᛗ");
        ANGLO_SAXON_CHAR_MAPPING.put("L", "ᛚ");
        ANGLO_SAXON_CHAR_MAPPING.put("D", "ᛞ");
        ANGLO_SAXON_CHAR_MAPPING.put("A", "ᚪ");
        ANGLO_SAXON_CHAR_MAPPING.put("Y", "ᚣ");
        ANGLO_SAXON_CHAR_MAPPING.put("K", "ᛣ");
        ANGLO_SAXON_CHAR_MAPPING.put("Q", "ᛢ");
        ANGLO_SAXON_CHAR_MAPPING.put(" ", "᛫");

    }

    private Map<String, String> charMapping;
    private Map<String, String> symbolGroupMapping;

    public void resetMapping() {
        charMapping = null;
        symbolGroupMapping = null;
    }

    public void initForAngloSaxon() {
        setMapping(ANGLO_SAXON_CHAR_MAPPING, ANGLO_SAXON_SYMBOL_GROUP_MAPPING);
    }

    public void initForFuthark() {
        setMapping(ELDER_FUTHARK_CHAR_MAPPING, ELDER_FUTHARK_SYMBOL_GROUP_MAPPING);
    }

    private void setMapping(Map<String, String> charMapping, Map<String, String> symbolGroupMapping) {
        this.charMapping = charMapping;
        this.symbolGroupMapping = symbolGroupMapping;
    }

    @Override
    public void keyTyped(KeyEvent e) {
        if (charMapping == null) {
            return;
        }
        char ch = e.getKeyChar();
        if (!Character.isLetter(ch)) {
            return;
        }
        String input = Character.toString(ch).toUpperCase();
        String replacement = charMapping.get(input);
        if (replacement != null) {
            e.setKeyChar(replacement.charAt(0));
        }
    }

    @Override
    public void keyReleased(KeyEvent e) {
        // empty
    }

    @Override
    public void keyPressed(KeyEvent e) {
        // empty
    }

    @Override
    public void insertString(FilterBypass fb, int offset, String string, AttributeSet attr) throws BadLocationException {
        super.insertString(fb, offset, string, attr);
    }

    public void addToComponent(JTextComponent target) {
        target.addKeyListener(this);
        ((AbstractDocument) target.getDocument()).setDocumentFilter(this);
    }

    @Override
    public void remove(FilterBypass fb, int offset, int length) throws BadLocationException {
        super.remove(fb, offset, length);
    }

    @Override
    public void replace(FilterBypass fb, int offset, int length, String text, AttributeSet attrs)
            throws BadLocationException {
        // System.out.println("Translator.replace()");
        super.replace(fb, offset, length, text, attrs);
        if (symbolGroupMapping == null) {
            return;
        }
        offset = Math.max(0, offset - 2);
//		length = text.length() + (offset == 0 ? 0 : 2);
        length = Math.min(fb.getDocument().getLength() - offset, 5);
        text = fb.getDocument().getText(offset, length);
        for (Map.Entry<String, String> entry : symbolGroupMapping.entrySet()) {
            int replaceOffset = text.indexOf(entry.getKey());
            if (replaceOffset > -1) {
                super.replace(fb, offset + replaceOffset, entry.getKey().length(), entry.getValue(), attrs);
                return;
            }
        }
    }
}
