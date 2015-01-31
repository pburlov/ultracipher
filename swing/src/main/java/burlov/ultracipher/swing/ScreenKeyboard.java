package burlov.ultracipher.swing;

import java.awt.BorderLayout;
import java.awt.Image;
import java.awt.TextField;
import java.awt.Toolkit;
import java.awt.datatransfer.Clipboard;
import java.awt.datatransfer.StringSelection;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;

import javax.swing.JButton;
import javax.swing.JFrame;
import javax.swing.JPanel;
import javax.swing.JToggleButton;

public class ScreenKeyboard extends JFrame implements ActionListener {
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    JPanel jPanel1 = new JPanel();
    // JTextField2 eingabefeld = new JTextField2();
    BorderLayout borderLayout1 = new BorderLayout();
    ScreenKeyboardPanel scrkeyboard = new ScreenKeyboardPanel();
    JPanel jPanel2 = new JPanel();
    JPanel jPanel4 = new JPanel();
    JToggleButton tbShowText = new JToggleButton();
    TextField eingabefeld = new TextField();
    JPanel jPanel3 = new JPanel();
    JButton btCopy = new JButton();
    JButton btClear = new JButton();
    BorderLayout borderLayout2 = new BorderLayout();
    BorderLayout borderLayout3 = new BorderLayout();

    /**
     * Parameter systemexit bestimmt was passiert beim Schliessen des Fensters.
     * Bei false wird das Fenster nur geschlossen, bei true wird die Methode
     * System.exit(0) aufgerufen
     */
    public ScreenKeyboard(Image icon) {
        try {
            jbInit();
        } catch (Exception e) {
            e.printStackTrace();
        }
        eingabefeld.setEchoChar('*');
        this.setTitle("Screen Keyboard Version 1.1");
        this.setIconImage(icon);
        this.pack();
        this.setResizable(false);
//		this.setIconImage(Toolkit.getDefaultToolkit().createImage(getClass().getResource("keyboard.gif")));
    }

    private void jbInit() throws Exception {
        jPanel1.setLayout(borderLayout1);
        jPanel2.setLayout(borderLayout3);
        jPanel4.setLayout(borderLayout2);
        tbShowText.setText("Show text");
        tbShowText.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                tbShowText_actionPerformed(e);
            }
        });
        eingabefeld.setEchoChar('*');
        eingabefeld.setColumns(40);
        btCopy.setText("Copy to clipboard");
        btCopy.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                btCopy_actionPerformed(e);
            }
        });
        btClear.setText("Clear clipboard");
        btClear.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                btClear_actionPerformed(e);
            }
        });
        jPanel3.add(btCopy, null);
        jPanel3.add(btClear, null);
        jPanel1.add(scrkeyboard, BorderLayout.CENTER);
        jPanel4.add(tbShowText, BorderLayout.WEST);
        jPanel4.add(eingabefeld, BorderLayout.CENTER);
        jPanel2.add(jPanel4, BorderLayout.NORTH);
        jPanel3.add(btCopy, null);
        jPanel3.add(btClear, null);
        jPanel2.add(jPanel3, BorderLayout.CENTER);
        jPanel1.add(jPanel2, BorderLayout.NORTH);
        scrkeyboard.addActionListener(this);
        this.getContentPane().add(jPanel1, BorderLayout.CENTER);
    }

    @Override
    public void actionPerformed(ActionEvent ae) {
        StringBuffer buffer = new StringBuffer(eingabefeld.getText());
        int offset = eingabefeld.getCaretPosition();
        buffer.insert(offset, ae.getActionCommand());
        eingabefeld.setText(buffer.toString());
        eingabefeld.setCaretPosition(++offset);
        eingabefeld.requestFocus();
    }

    void tbShowText_actionPerformed(ActionEvent e) {
        if (tbShowText.isSelected()) {
            eingabefeld.setEchoChar('\00');
            int offset = eingabefeld.getCaretPosition();
            eingabefeld.setText(eingabefeld.getText());
            eingabefeld.setCaretPosition(offset);
            eingabefeld.requestFocus();
        } else {
            int offset = eingabefeld.getCaretPosition();
            eingabefeld.setEchoChar('*');
            eingabefeld.setText(eingabefeld.getText());
            eingabefeld.setCaretPosition(offset);
            eingabefeld.requestFocus();
        }
    }

    void btCopy_actionPerformed(ActionEvent e) {
        Clipboard clp = Toolkit.getDefaultToolkit().getSystemClipboard();
        StringSelection selection = new StringSelection(eingabefeld.getText());
        clp.setContents(selection, selection);

    }

    void btClear_actionPerformed(ActionEvent e) {
        Toolkit.getDefaultToolkit().getSystemClipboard().setContents(new StringSelection(""), new StringSelection(""));
    }

}