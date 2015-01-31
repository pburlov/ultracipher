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

import java.awt.Color;
import java.awt.Component;
import java.awt.GridBagConstraints;
import java.awt.GridBagLayout;
import java.awt.Insets;
import java.awt.KeyboardFocusManager;

import javax.swing.ImageIcon;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.JTextArea;
import javax.swing.JTextField;
import javax.swing.JToggleButton;
import javax.swing.event.ChangeEvent;
import javax.swing.event.ChangeListener;
import javax.swing.event.DocumentEvent;
import javax.swing.event.DocumentListener;

import de.burlov.ultracipher.core.DataEntry;

/**
 * Klasse zum Anzeigen und Editieren eines Datensatzes
 * <p/>
 * Created 23.06.2009
 *
 * @author paul
 */
public class EditDataPanel extends JPanel {

    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private ImageIcon lockedImage;
    private JToggleButton unlockButton = new JToggleButton(lockedImage);
    private ImageIcon unlockedImage;

    static {
    }

    private JTextField tfName = new JTextField();
    private JTextField tfTags = new JTextField();
    private JTextArea taData = new JTextArea();
    private DataEntry data;

    public EditDataPanel(Translator translator) {
        super();
        lockedImage = new ImageIcon(EditDataPanel.class.getResource("lock_closed.png"));
        unlockedImage = new ImageIcon(getClass().getResource("lock_open.png"));

        translator.addToComponent(taData);
        translator.addToComponent(tfName);
        translator.addToComponent(tfTags);
        GridBagLayout gb = new GridBagLayout();
        GridBagConstraints c = new GridBagConstraints();
        setLayout(gb);

        JLabel label = new JLabel("Label");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.WEST;
        c.gridwidth = 1;
        c.weightx = 0.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 0;
        c.gridy = 0;
        gb.setConstraints(label, c);
        add(label);

        c.fill = GridBagConstraints.HORIZONTAL;
        c.anchor = GridBagConstraints.NORTHWEST;
        c.gridwidth = 1;
        c.weightx = 1.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 1;
        c.gridy = 0;
        gb.setConstraints(tfName, c);
        add(tfName);

        label = new JLabel("Tags");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.WEST;
        c.gridwidth = 1;
        c.weightx = 0.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 0;
        c.gridy = 1;
        gb.setConstraints(label, c);
        add(label);

        c.fill = GridBagConstraints.HORIZONTAL;
        c.anchor = GridBagConstraints.NORTHWEST;
        c.gridwidth = 1;
        c.weightx = 0.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 1;
        c.gridy = 1;
        gb.setConstraints(tfTags, c);
        add(tfTags);

        label = new JLabel("Data");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.SOUTHWEST;
        c.gridwidth = 3;
        c.weightx = 0.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 0;
        c.gridy = 2;
        gb.setConstraints(label, c);
        add(label);


        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHWEST;
        c.gridwidth = 1;
        c.gridheight = 3;
        c.weightx = 0.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 2;
        c.gridy = 0;
        gb.setConstraints(unlockButton, c);
        add(unlockButton);

        c.fill = GridBagConstraints.BOTH;
        c.anchor = GridBagConstraints.NORTHWEST;
        c.gridwidth = GridBagConstraints.REMAINDER;
        c.gridheight = GridBagConstraints.REMAINDER;
        c.weightx = 1.0;
        c.weighty = 1.0;
        c.insets = new Insets(2, 2, 2, 2);
        c.gridx = 0;
        c.gridy = 3;
        JScrollPane scroll = new JScrollPane(taData);
        scroll.setOpaque(false);
        scroll.setBackground(null);
        gb.setConstraints(scroll, c);
        add(scroll);
        /*
         * Listener Registrieren um Aenderungen an Feldern zu tracken und Model
		 * Objekt damit upzudaten
		 */
        tfName.getDocument().addDocumentListener(new DocumentListener() {

            @Override
            public void removeUpdate(DocumentEvent arg0) {
                update();
            }

            @Override
            public void insertUpdate(DocumentEvent arg0) {
                update();
            }

            @Override
            public void changedUpdate(DocumentEvent arg0) {
                update();
            }

            private void update() {
                if (data != null) {
                    data.setName(tfName.getText());
                    data.updated();
                    SwingGuiApplication.getInstance().updateNeedSave(true);
                }
            }
        });

        tfTags.getDocument().addDocumentListener(new DocumentListener() {

            private void update() {
                if (data != null) {
                    data.setTags(tfTags.getText());
                    data.updated();
                    SwingGuiApplication.getInstance().updateNeedSave(true);
                }
            }

            @Override
            public void removeUpdate(DocumentEvent e) {
                update();
            }

            @Override
            public void insertUpdate(DocumentEvent e) {
                update();
            }

            @Override
            public void changedUpdate(DocumentEvent e) {
                update();
            }
        });

        taData.getDocument().addDocumentListener(new DocumentListener() {
            private void update() {
                if (data != null) {
                    data.setText(taData.getText());
                    data.updated();
                    SwingGuiApplication.getInstance().updateNeedSave(true);
                }
            }

            @Override
            public void removeUpdate(DocumentEvent e) {
                update();
            }

            @Override
            public void insertUpdate(DocumentEvent e) {
                update();
            }

            @Override
            public void changedUpdate(DocumentEvent e) {
                update();
            }
        });

        unlockButton.addChangeListener(new ChangeListener() {

            @Override
            public void stateChanged(ChangeEvent e) {
                setEditableImpl(unlockButton.isSelected());
                unlockButton.setIcon(unlockButton.isSelected() ? unlockedImage : lockedImage);
            }
        });
        unlockButton.setFocusable(false);
        setEditable(false);
        TextPopup.installTextPopupMenu(taData);
        TextPopup.installTextPopupMenu(tfName);
        TextPopup.installTextPopupMenu(tfTags);
        editData(null, false);
    }

    public void editData(DataEntry data, boolean requestFocus) {
		/*
		 * Zuers den data Object auf null setzten damit DocumentListener keine
		 * Aenderungen setzt als Folge von setText() Methodenaufrufen
		 */
        this.data = null;
        if (data != null) {
            setEnabled(true);
            tfName.setText(data.getName());
            tfTags.setText(data.getTags());
            taData.setText(data.getText());
            taData.setCaretPosition(0);
            if (requestFocus) {
				/*
				 * Eingabefocus auf Namensfeld setzen
				 */
                tfName.requestFocusInWindow();
            }

			/*
			 * Erst hier nachdem alle Eingabefelder initialisiert wurden den
			 * Datenobjekt setzten. Somit wird verhindert dass DocumentListener
			 * unnoetigerweise Aenderungen in Datenobject schreibt
			 */
            this.data = data;
        } else {
            setEnabled(false);
        }

    }

    @Override
    public void setEnabled(boolean enabled) {
        unlockButton.setEnabled(enabled);
        super.setEnabled(enabled);
        if (enabled) {
            tfName.setEnabled(true);
            tfName.setBackground(Color.WHITE);

            tfTags.setEnabled(true);
            tfTags.setBackground(Color.WHITE);

            taData.setEnabled(true);
            taData.setBackground(Color.WHITE);
        } else {
			/*
			 * Eingabefelder loeschen und disablen
			 */
            tfName.setText("");
            tfName.setEnabled(false);
            tfName.setBackground(Color.LIGHT_GRAY);
            tfTags.setText("");
            tfTags.setEnabled(false);
            tfTags.setBackground(Color.LIGHT_GRAY);
            taData.setText("");
            taData.setEnabled(false);
            taData.setBackground(Color.LIGHT_GRAY);
        }
    }

    public DataEntry getData() {
        return data;
    }

    public void addNameChangeListener(DocumentListener listener) {
        tfName.getDocument().addDocumentListener(listener);
    }

    public void setEditable(boolean editable) {
        unlockButton.setSelected(editable);
        setEditableImpl(editable);
    }

    private void setEditableImpl(boolean editable) {
        Component focusOwner = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
        tfName.setEditable(editable);
        tfTags.setEditable(editable);
        taData.setEditable(editable);
        if (focusOwner != null) {
            focusOwner.transferFocus();
            focusOwner.requestFocus();
        }
    }
}
