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

import java.awt.BorderLayout;
import java.util.Collection;

import javax.swing.JList;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.event.ListSelectionListener;

import de.burlov.ultracipher.core.DataEntry;

/**
 * Zeigt Liste mit Dateneintraegen
 * <p/>
 * Created 06.07.2009
 *
 * @author paul
 */
public class EntryListPanel extends JPanel {
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private JList jList = new JList();

    public EntryListPanel() {
        super(new BorderLayout());
        JScrollPane scroll = new JScrollPane(jList);
        this.add(scroll);
    }

    public void showEntries(Collection<DataEntry> entries) {
        jList.setListData(entries.toArray());
    }

    /**
     * Registriert {@link ListSelectionListener} bei Liste der Eintraege
     *
     * @param arg0
     */
    public void addListSelectionListener(ListSelectionListener arg0) {
        jList.addListSelectionListener(arg0);
    }

    public DataEntry getSelectedEntry() {
        return (DataEntry) jList.getSelectedValue();
    }
}
