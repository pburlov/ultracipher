/*
 	Copyright (C) 2009 Paul Burlov
 	
 	
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
package burlov.ultracipher.swing;

import java.awt.FlowLayout;
import java.awt.Frame;
import java.awt.GridBagConstraints;
import java.awt.GridBagLayout;
import java.awt.Insets;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.util.Arrays;

import javax.swing.JButton;
import javax.swing.JDialog;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JPasswordField;

/**
 * Created 04.05.2009
 *
 * @author paul
 */
public class PasswordDialog extends JDialog {
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private JPasswordField tfPassword1 = new JPasswordField(20);
    private JPasswordField tfPassword2 = new JPasswordField(20);
    private JButton btOk = new JButton("Ok");
    private JButton btCancel = new JButton("Cancel");
    private char[] psw;

    protected PasswordDialog(Frame owner, final boolean withConfirm, String header) {
        super(owner, header, true);
        GridBagLayout gb = new GridBagLayout();
        GridBagConstraints c = new GridBagConstraints();
        setLayout(gb);
        JLabel label = new JLabel("Passphrase");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.WEST;
        c.gridwidth = 1;
        c.weightx = 0.0;
        c.insets = new Insets(0, 2, 0, 2);
        c.gridx = 0;
        gb.setConstraints(label, c);
        add(label);

        c.fill = GridBagConstraints.HORIZONTAL;
        c.gridwidth = GridBagConstraints.REMAINDER;
        c.weightx = 1.0;
        c.insets = new Insets(0, 2, 0, 2);
        c.gridx = 1;
        gb.setConstraints(tfPassword1, c);
        add(tfPassword1);

        if (withConfirm) {
            label = new JLabel("Passphrase (confirm)");
            c.fill = GridBagConstraints.NONE;
            c.anchor = GridBagConstraints.WEST;
            c.gridwidth = 1;
            c.weightx = 0.0;
            c.insets = new Insets(0, 2, 0, 2);
            c.gridx = 0;
            gb.setConstraints(label, c);
            add(label);

            c.fill = GridBagConstraints.HORIZONTAL;
            c.gridwidth = GridBagConstraints.REMAINDER;
            c.weightx = 1.0;
            c.insets = new Insets(0, 2, 0, 2);
            c.gridx = 1;
            gb.setConstraints(tfPassword2, c);
            add(tfPassword2);
        }
        // ===========================
        JPanel panel = new JPanel(new FlowLayout(FlowLayout.RIGHT));
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHEAST;
        c.weightx = 0.0;
        c.gridwidth = 2;
        c.insets = new Insets(4, 4, 4, 4);
        c.gridx = 0;
        gb.setConstraints(panel, c);
        add(panel);
        panel.add(btCancel);
        panel.add(btOk);
        pack();
        setResizable(false);

        btOk.setText("Ok");
        btOk.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                psw = tfPassword1.getPassword();
                if (withConfirm && !Arrays.equals(psw, tfPassword2.getPassword())) {
                    JOptionPane.showMessageDialog(PasswordDialog.this, "Invalid passphrase confirmation", "Error", JOptionPane.ERROR_MESSAGE);
                    Arrays.fill(psw, ' ');
                    psw = null;
                    //tfPassword1.setText("");
                    tfPassword2.setText("");
                    tfPassword1.requestFocusInWindow();
                } else {
                    setVisible(false);
                    dispose();
                }
            }
        });
        btCancel.setText("Cancel");
        btCancel.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                setVisible(false);
                dispose();
            }
        });
        btOk.setDefaultCapable(true);
        this.getRootPane().setDefaultButton(btOk);
    }

    static public void main(String... args) {
        PasswordDialog dg = new PasswordDialog(null, true, "Psw");
        dg.setVisible(true);
        System.out.println(new String(dg.getPassphrase()));
    }

    /**
     * Liefert eingegebene Passphrase oder null falls Eingabe abgebrochen wurde
     *
     * @return
     */
    public char[] getPassphrase() {
        return psw;
    }
}
