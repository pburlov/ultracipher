/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 10, 2012
 */
package burlov.ultracipher.swing;

import org.apache.commons.lang3.StringUtils;

import java.awt.BorderLayout;
import java.awt.FlowLayout;
import java.awt.Frame;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.util.Collection;

import javax.swing.GroupLayout;
import javax.swing.GroupLayout.Alignment;
import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JDialog;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JTextField;

import de.burlov.ultracipher.core.mail.EmailCredentials;
import de.burlov.ultracipher.core.mail.SupportedDomain;

public class SyncAccountSettingsDialog extends JDialog {
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private JTextField account = new JTextField(20);
    private JTextField password = new JTextField(32);
    private JComboBox domains;
    private JLabel comment = new JLabel();
    private boolean cancelled = true;

    public SyncAccountSettingsDialog(Frame parent, Collection<SupportedDomain> possibleDomains, EmailCredentials template) {
        super();
        domains = new JComboBox(possibleDomains.toArray());
        domains.setEditable(false);
        domains.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                comment.setText(((SupportedDomain) domains.getSelectedItem()).comment + " ");
            }
        });
        if (template != null) {
            account.setText(template.getUserPart());
            password.setText(template.getPassword());
            for (SupportedDomain dom : possibleDomains) {
                if (dom.matches(template.getEmailaddress())) {
                    domains.setSelectedItem(dom);
                }
            }
        }
        comment.setText(((SupportedDomain) domains.getSelectedItem()).comment + " ");
        setModal(true);

        JComponent panel = new JPanel();
        this.getContentPane().add(panel, BorderLayout.CENTER);
        GroupLayout layout = new GroupLayout(panel);
        panel.setLayout(layout);
        // layout.setAutoCreateGaps(true);
        // layout.setAutoCreateContainerGaps(true);
        JLabel labelEmail = new JLabel("Email:");
        JLabel labelPassword = new JLabel("Password: ");
        JLabel labelAt = new JLabel("@");

        JButton btOk = new JButton("Ok");
        JButton btCancel = new JButton("Cancel");
        JPanel btPanel = new JPanel(new FlowLayout(FlowLayout.RIGHT));
        btPanel.add(btOk);
        btPanel.add(btCancel);
        this.add(btPanel, BorderLayout.SOUTH);

        GroupLayout.SequentialGroup hGroup = layout.createSequentialGroup();
        hGroup.addGroup(layout.createParallelGroup().addComponent(labelEmail).addComponent(labelPassword));
        hGroup.addGroup(layout.createParallelGroup().addGroup(layout.createSequentialGroup().addComponent(account).addComponent(labelAt).addComponent(domains))
                .addComponent(password).addComponent(comment));
        layout.setHorizontalGroup(hGroup);

        // Create a sequential group for the vertical axis.
        GroupLayout.SequentialGroup vGroup = layout.createSequentialGroup();
        vGroup.addGroup(layout.createParallelGroup(Alignment.CENTER).addComponent(labelEmail)
                .addGroup(layout.createParallelGroup().addComponent(account).addComponent(labelAt).addComponent(domains)));
        vGroup.addGroup(layout.createParallelGroup(Alignment.CENTER).addComponent(labelPassword).addComponent(password));
        vGroup.addGroup(layout.createParallelGroup().addComponent(comment));
        layout.setVerticalGroup(vGroup);
        this.pack();
        this.setResizable(false);

        btOk.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                cancelled = false;
                SyncAccountSettingsDialog.this.setVisible(false);
                dispose();
            }
        });

        btCancel.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                cancelled = true;
                account.setText("");
                password.setText("");
                SyncAccountSettingsDialog.this.setVisible(false);
                dispose();
            }
        });
        this.getRootPane().setDefaultButton(btOk);
        TextPopup.installTextPopupMenu(account);
        TextPopup.installTextPopupMenu(password);
    }

    /**
     * @return 'null' falls Eingabe abgebrochen
     */
    public EmailCredentials getEmailCredentials() {
        if (cancelled) {
            return null;
        }
        if (StringUtils.isBlank(account.getText())) {
            return new EmailCredentials("", "");
        }
        String email = account.getText() + "@" + domains.getSelectedItem();
        return new EmailCredentials(email, password.getText());
    }

}
