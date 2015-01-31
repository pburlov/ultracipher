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

import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JDialog;
import javax.swing.JLabel;
import javax.swing.JPanel;

import de.burlov.ultracipher.core.CSVSettings;

/**
 * Einstellungsdialog fuer CSV Import/Export
 * <p/>
 * Created 04.05.2009
 *
 * @author paul
 */
public class CSVSettingsDialog extends JDialog {
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    static final private Integer[] columns = new Integer[]{1, 2, 3, 4, 5};
    private JComboBox nameColumn = new JComboBox(columns);
    private JComboBox tagsColumn = new JComboBox(columns);
    private JComboBox dataColumn = new JComboBox(columns);
    static final private Character[] separators = new Character[]{',', ';', '|'};
    private JComboBox separator = new JComboBox(separators);
    static final private Character[] quotes = new Character[]{'\'', '"'};
    private JComboBox quote = new JComboBox(quotes);

    private JButton btOk = new JButton("Ok");
    private JButton btCancel = new JButton("Cancel");
    private boolean ok = false;

    protected CSVSettingsDialog(Frame owner) {
        super(owner, "CSV settings", true);
        GridBagLayout gb = new GridBagLayout();
        GridBagConstraints c = new GridBagConstraints();
        setLayout(gb);
        JLabel label = new JLabel("Name column ");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHWEST;
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
        gb.setConstraints(nameColumn, c);
        add(nameColumn);

        label = new JLabel("Tags column ");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHWEST;
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
        gb.setConstraints(tagsColumn, c);
        add(tagsColumn);
        tagsColumn.setSelectedIndex(1);

        label = new JLabel("Text column ");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHWEST;
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
        gb.setConstraints(dataColumn, c);
        add(dataColumn);
        dataColumn.setSelectedIndex(2);

        label = new JLabel("Separator char ");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHWEST;
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
        gb.setConstraints(separator, c);
        add(separator);

        label = new JLabel("Quote char ");
        c.fill = GridBagConstraints.NONE;
        c.anchor = GridBagConstraints.NORTHWEST;
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
        gb.setConstraints(quote, c);
        add(quote);

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
        panel.add(btOk);
        panel.add(btCancel);
        pack();
        setResizable(false);

        btOk.setText("Ok");
        btOk.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                ok = true;
                setVisible(false);
                dispose();
            }
        });
        btCancel.setText("Cancel");
        btCancel.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                ok = false;
                setVisible(false);
                dispose();
            }
        });
        btOk.setDefaultCapable(true);
        this.getRootPane().setDefaultButton(btOk);
    }

    /**
     * @return null falls vom Benutzer abgebrochen
     */
    public CSVSettings getSettings() {
        if (!ok) {
            return null;
        }
        CSVSettings ret = new CSVSettings();
        ret.setDataColumn((Integer) dataColumn.getSelectedItem() - 1);
        ret.setNameColumn((Integer) nameColumn.getSelectedItem() - 1);
        ret.setTagsColumn((Integer) tagsColumn.getSelectedItem() - 1);
        ret.setSeparator((Character) separator.getSelectedItem());
        ret.setQuoteChar((Character) quote.getSelectedItem());
        return ret;
    }

    // public static void main(String[] args)
    // {
    // CSVSettingsDialog dlg = new CSVSettingsDialog(null);
    // dlg.setVisible(true);
    // }
}
