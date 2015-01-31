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

import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;

import javax.swing.Action;
import javax.swing.JPopupMenu;
import javax.swing.KeyStroke;
import javax.swing.text.DefaultEditorKit;
import javax.swing.text.JTextComponent;

public class TextPopup extends JPopupMenu {

    /**
     *
     */
    private static final long serialVersionUID = 1L;

    public TextPopup() {
        Action ac = null;
        ac = new DefaultEditorKit.CutAction();
        ac.putValue(Action.NAME, "Cut");
        ac.putValue(Action.ACCELERATOR_KEY, KeyStroke.getKeyStroke("control X"));
        add(ac);
        ac = new DefaultEditorKit.CopyAction();
        ac.putValue(Action.NAME, "Copy");
        ac.putValue(Action.ACCELERATOR_KEY, KeyStroke.getKeyStroke("control C"));
        add(ac);
        ac = new DefaultEditorKit.PasteAction();
        ac.putValue(Action.NAME, "Paste");
        ac.putValue(Action.ACCELERATOR_KEY, KeyStroke.getKeyStroke("control V"));
        add(ac);
    }

    public static void installTextPopupMenu(JTextComponent target) {
        target.addMouseListener(new MouseAdapter() {
            private TextPopup textPopup = new TextPopup();

            @Override
            public void mousePressed(MouseEvent e) {
                if (e.isPopupTrigger()) {
                    showTextPopup(e);
                }
            }

            @Override
            public void mouseReleased(MouseEvent e) {
                showTextPopup(e);
            }

            void showTextPopup(MouseEvent e) {
                if (e.isPopupTrigger() && e.getComponent().isEnabled()) {
                    e.getComponent().requestFocusInWindow();
                    textPopup.show(e.getComponent(), e.getX(), e.getY());
                }
            }
        });

    }

}
