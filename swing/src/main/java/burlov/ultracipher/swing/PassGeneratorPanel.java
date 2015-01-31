package burlov.ultracipher.swing;

import org.apache.commons.lang3.RandomStringUtils;

import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;

import javax.swing.BoxLayout;
import javax.swing.ImageIcon;
import javax.swing.JButton;
import javax.swing.JPanel;
import javax.swing.JSpinner;
import javax.swing.JTextField;
import javax.swing.SpinnerNumberModel;

/**
 * Title: JPassKeeper Description: Generiert zuf�llige Passw�rter. Copyright:
 * Copyright (c) 2001 Company:
 *
 * @author
 * @version 1.0
 */

public class PassGeneratorPanel extends JPanel implements ActionListener {

    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private JTextField passfield = new JTextField(20);
    private JSpinner numberOfChars = new JSpinner(new SpinnerNumberModel(20, 4, 40, 1));

    /**
     * Parameter systemexit bestimmt was passiert beim Schliessen des Fensters.
     * Bei false wird das Fenster nur geschlossen, bei true wird die Methode
     * System.exit(0) aufgerufen
     */
    public PassGeneratorPanel() {
        this.setLayout(new BoxLayout(this, BoxLayout.X_AXIS));
        // setLayout(new FlowLayout(FlowLayout.RIGHT));

        // add(Box.createHorizontalGlue());
        add(passfield);
        add(numberOfChars);
        JButton button = new JButton(new ImageIcon(SwingGuiApplication.class.getResource("refresh.png")));
        button.setToolTipText("Generate password");
        button.addActionListener(this);
        add(button);
        button = new JButton(new ImageIcon(SwingGuiApplication.class.getResource("copy.png")));
        button.setToolTipText("Copy to clipboard");
        button.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                if (passfield.getSelectedText() == null) {
                    passfield.selectAll();
                }
                passfield.copy();
            }
        });
        add(button);
        TextPopup.installTextPopupMenu(passfield);
        generateRandom();
    }

    private void generateRandom() {
        passfield.setText(RandomStringUtils.randomAlphanumeric(((Number) numberOfChars.getValue()).intValue()));
    }

    @Override
    public void actionPerformed(ActionEvent ac) {
        generateRandom();
    }

}