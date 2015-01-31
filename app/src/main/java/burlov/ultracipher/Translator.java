package burlov.ultracipher;

import android.text.Editable;
import android.text.TextWatcher;

import java.util.LinkedHashMap;
import java.util.Map;

public class Translator implements TextWatcher {
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
    private int start;
    private int count;
    private boolean replaceInProgress = false;

    public Translator resetMapping() {
        charMapping = null;
        symbolGroupMapping = null;
        return this;
    }

    public boolean isSystem() {
        return charMapping == null;
    }

    public Translator initForAngloSaxon() {
        setMapping(ANGLO_SAXON_CHAR_MAPPING, ANGLO_SAXON_SYMBOL_GROUP_MAPPING);
        return this;
    }

    public boolean isAngloSaxon() {
        return charMapping == ANGLO_SAXON_CHAR_MAPPING;
    }

    public Translator initForFuthark() {
        setMapping(ELDER_FUTHARK_CHAR_MAPPING, ELDER_FUTHARK_SYMBOL_GROUP_MAPPING);
        return this;
    }

    public boolean isFuthark() {
        return charMapping == ELDER_FUTHARK_CHAR_MAPPING;
    }

    private void setMapping(Map<String, String> charMapping, Map<String, String> symbolGroupMapping) {
        this.charMapping = charMapping;
        this.symbolGroupMapping = symbolGroupMapping;
    }

    @Override
    public void afterTextChanged(Editable s) {
        if (charMapping == null || count == 0 || replaceInProgress) {
            return;
        }
        replaceInProgress = true;
        boolean replaced = false;
        String changedSubstring = s.subSequence(start, start + count).toString().toUpperCase();
        for (Map.Entry<String, String> entry : charMapping.entrySet()) {
            if (changedSubstring.contains(entry.getKey())) {
                replaced = true;
                changedSubstring = changedSubstring.replace(entry.getKey(), entry.getValue());
            }
        }
        if (replaced) {
            s.replace(start, start + count, changedSubstring);
        }
        if (symbolGroupMapping == null) {
            replaceInProgress = false;
            return;
        }
        replaced = false;
        String text = s.toString();
        for (Map.Entry<String, String> entry : symbolGroupMapping.entrySet()) {
            if (text.contains(entry.getKey())) {
                replaced = true;
                text = text.replace(entry.getKey(), entry.getValue());
            }
        }
        if (replaced) {
            s.replace(0, s.length(), text);
        }
        replaceInProgress = false;
    }

    @Override
    public void beforeTextChanged(CharSequence s, int start, int count, int after) {
    }

    @Override
    public void onTextChanged(CharSequence s, int start, int before, int count) {
        if (replaceInProgress) {
            return;
        }
        this.start = start;
        this.count = count;
    }

}
