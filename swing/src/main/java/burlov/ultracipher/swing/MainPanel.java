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

import org.apache.commons.lang3.StringUtils;

import java.awt.BorderLayout;
import java.awt.event.ActionEvent;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.util.List;

import javax.swing.AbstractAction;
import javax.swing.Action;
import javax.swing.DefaultListModel;
import javax.swing.ImageIcon;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JPopupMenu;
import javax.swing.JScrollPane;
import javax.swing.JSplitPane;
import javax.swing.JTextField;
import javax.swing.KeyStroke;
import javax.swing.event.DocumentEvent;
import javax.swing.event.DocumentListener;
import javax.swing.event.ListSelectionEvent;
import javax.swing.event.ListSelectionListener;

import de.burlov.ultracipher.core.DataEntry;
import de.burlov.ultracipher.core.Finder;

/**
 * Created 23.06.2009
 *
 * @author paul
 */
public class MainPanel extends JPanel {
    /**
     *
     */
    private static final long serialVersionUID = 1L;

    private JSplitPane splitPane = new JSplitPane(JSplitPane.HORIZONTAL_SPLIT);
    private JTextField searchField = new JTextField();
    private EditDataPanel editDataPanel;
    private JList searchResults = new JList();
    private DefaultListModel searchResultModel = new DefaultListModel();
    private JPopupMenu textPopup = new TextPopup();
    private JPopupMenu listPopup = new JPopupMenu();


    public MainPanel(Translator translator) {
        editDataPanel = new EditDataPanel(translator);
        translator.addToComponent(searchField);
        listPopup.add(getNewEntryAction());
        listPopup.add(getDeleteEntryAction());

        setLayout(new BorderLayout());
        add(splitPane);

		/*
         * Suchpanel initialisieren
		 */
        JPanel panel = new JPanel(new BorderLayout());
        JPanel searchPanel = new JPanel(new BorderLayout());
        searchPanel.add(new JLabel(new ImageIcon(getClass().getResource("find.png"))), BorderLayout.WEST);
        searchPanel.add(searchField, BorderLayout.CENTER);
        searchField.setToolTipText("Search");
        panel.add(searchPanel, BorderLayout.NORTH);
        panel.add(new JScrollPane(searchResults), BorderLayout.CENTER);
        splitPane.setLeftComponent(panel);

		/*
         * Anzeigepanel initialisieren
		 */
        panel = new JPanel(new BorderLayout());
        panel.add(editDataPanel, BorderLayout.CENTER);
        panel.add(new PassGeneratorPanel(), BorderLayout.SOUTH);
        splitPane.setRightComponent(panel);

        searchResults.addMouseListener(new MouseAdapter() {

            @Override
            public void mousePressed(MouseEvent e) {
                showDeletePopup(e);
            }

            @Override
            public void mouseReleased(MouseEvent e) {
                showDeletePopup(e);
            }

            private void showDeletePopup(MouseEvent e) {
                if (!e.isPopupTrigger()) {
                    return;
                }
                int index = searchResults.locationToIndex(e.getPoint());
                if (index > -1) {
                    searchResults.setSelectedIndex(index);
                }
                listPopup.show(e.getComponent(), e.getX(), e.getY());
            }
        });
        searchResults.addListSelectionListener(new ListSelectionListener() {

            @Override
            public void valueChanged(ListSelectionEvent e) {
                editDataPanel.editData((DataEntry) searchResults.getSelectedValue(), false);
            }
        });
        searchField.getDocument().addDocumentListener(new DocumentListener() {

            @Override
            public void removeUpdate(DocumentEvent e) {
                initResultList();
            }

            @Override
            public void insertUpdate(DocumentEvent e) {
                initResultList();
            }

            @Override
            public void changedUpdate(DocumentEvent e) {
                initResultList();
            }
        });

        editDataPanel.addNameChangeListener(new DocumentListener() {

            @Override
            public void removeUpdate(DocumentEvent e) {
                int index = searchResultModel.indexOf(editDataPanel.getData());
                if (index >= 0) {
                    searchResultModel.set(index, editDataPanel.getData());
                }
            }

            @Override
            public void insertUpdate(DocumentEvent e) {
                int index = searchResultModel.indexOf(editDataPanel.getData());
                if (index >= 0) {
                    searchResultModel.set(index, editDataPanel.getData());
                }
            }

            @Override
            public void changedUpdate(DocumentEvent e) {
                int index = searchResultModel.indexOf(editDataPanel.getData());
                if (index >= 0) {
                    searchResultModel.set(index, editDataPanel.getData());
                }
            }
        });
        searchField.addMouseListener(new MouseAdapter() {
            @Override
            public void mousePressed(MouseEvent e) {
                if (e.isPopupTrigger()) {
                    showTextPopup(e);
                } else {
//					searchField.selectAll();
                }
            }

            @Override
            public void mouseReleased(MouseEvent e) {
                showTextPopup(e);
            }
        });
//		searchField.addFocusListener(new FocusListener() {
//			@Override
//			public void focusLost(FocusEvent e) {
//				System.out.println("MainPanel.MainPanel().new FocusListener() {...}.focusLost()");
//			}
//			
//			@Override
//			public void focusGained(FocusEvent e) {
//				System.out.println("MainPanel.MainPanel().new FocusListener() {...}.focusGained()");
//				//searchField.selectAll();
//			}
//		});
    }

    private void showTextPopup(MouseEvent e) {
        if (e.isPopupTrigger()) {
            e.getComponent().requestFocusInWindow();
            textPopup.show(e.getComponent(), e.getX(), e.getY());
        }
    }

    public void init() {
        initResultList();
        if (searchResultModel.getSize() > 0) {
            searchResults.setSelectedIndex(0);
        }
    }

    private void initResultList() {
        if (SwingGuiApplication.getInstance().getDatabase() == null) {
            return;
        }
        List<DataEntry> allEntries = SwingGuiApplication.getInstance().getDatabase().getEntries();
        List<DataEntry> foundedEntries = allEntries;
        if (!StringUtils.isBlank(searchField.getText())) {
            Finder finder = new Finder();
            foundedEntries = finder.findEntries(searchField.getText(), allEntries, Integer.MAX_VALUE);
        }
        searchResultModel = new DefaultListModel();
        for (DataEntry entry : foundedEntries) {
            searchResultModel.addElement(entry);
        }
        searchResults.setModel(searchResultModel);
        if (foundedEntries.size() > 0) {
            searchResults.setSelectedIndex(0);
        }
    }

    private void deleteCurrentEntry() {
        DataEntry entry = editDataPanel.getData();
        if (entry != null) {
            // int ret = JOptionPane.showOptionDialog(getMainFrame(),
            // "Delete entry?", "Confirm",
            // JOptionPane.YES_NO_OPTION, JOptionPane.QUESTION_MESSAGE, null,
            // null, JOptionPane.NO_OPTION);
            int ret = JOptionPane.showConfirmDialog(SwingGuiApplication.getInstance().getMainFrame(), "Delete entry?", "Warning", JOptionPane.OK_CANCEL_OPTION,
                    JOptionPane.WARNING_MESSAGE);
            if (ret == JOptionPane.OK_OPTION) {
                SwingGuiApplication.getInstance().getDatabase().deleteEntry(entry);
                SwingGuiApplication.getInstance().updateNeedSave(true);
                searchResultModel.removeElement(entry);
                editDataPanel.editData(null, false);
                searchResults.clearSelection();
            }
        }

    }

    private void newEntry() {
        DataEntry entry = SwingGuiApplication.getInstance().getDatabase().addNewEntry();
        SwingGuiApplication.getInstance().updateNeedSave(true);
        searchResultModel.add(0, entry);
        searchResults.clearSelection();
        searchResults.setSelectedValue(entry, true);
        editDataPanel.editData(entry, true);
    }

    /**
     * @return aktuell angezeige Datensatz
     */
    public DataEntry getEditedEntry() {
        return editDataPanel.getData();
    }

    public Action getDeleteEntryAction() {
        Action ret = new AbstractAction("deleteEntryAction") {

            /**
             *
             */
            private static final long serialVersionUID = 1L;

            @Override
            public void actionPerformed(ActionEvent e) {
                deleteCurrentEntry();
            }
        };
        ret.putValue(Action.NAME, "Delete entry");
        ret.putValue(Action.ACCELERATOR_KEY, KeyStroke.getKeyStroke("control D"));
        return ret;
    }

    public Action getNewEntryAction() {
        Action ret = new AbstractAction("deleteEntryAction") {

            /**
             *
             */
            private static final long serialVersionUID = 1L;

            @Override
            public void actionPerformed(ActionEvent e) {
                getEditDataPanel().setEditable(true);
                newEntry();
            }
        };
        ret.putValue(Action.NAME, "New entry");
        ret.putValue(Action.ACCELERATOR_KEY, KeyStroke.getKeyStroke("control N"));
        return ret;
    }

    public EditDataPanel getEditDataPanel() {
        return editDataPanel;
    }
}
