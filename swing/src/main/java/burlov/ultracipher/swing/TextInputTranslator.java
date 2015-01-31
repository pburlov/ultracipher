package burlov.ultracipher.swing;

import java.awt.event.KeyEvent;
import java.awt.event.KeyListener;
import java.util.Map;

import javax.swing.text.JTextComponent;

public class TextInputTranslator implements KeyListener {
    private final Map<String, String> mapping;
    private final JTextComponent textComponent;

    public TextInputTranslator(Map<String, String> mapping, JTextComponent textComponent) {
        super();
        this.mapping = mapping;
        this.textComponent = textComponent;
        textComponent.addKeyListener(this);
    }

    @Override
    public void keyTyped(KeyEvent e) {
        // TODO Auto-generated method stub

    }

    @Override
    public void keyPressed(KeyEvent e) {
        // TODO Auto-generated method stub

    }

    @Override
    public void keyReleased(KeyEvent e) {
        // TODO Auto-generated method stub

    }

}
