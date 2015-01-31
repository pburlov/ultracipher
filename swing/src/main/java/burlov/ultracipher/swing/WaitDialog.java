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

import java.awt.Frame;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;

import javax.swing.BoxLayout;
import javax.swing.JDialog;
import javax.swing.JLabel;
import javax.swing.JProgressBar;
import javax.swing.SwingWorker;

/**
 * Zeigt ein kleines modales Dialog mit einem Text und ProgressBar
 * <p/>
 * Created 29.06.2009
 *
 * @author paul
 */
public class WaitDialog extends JDialog {

    /**
     *
     */
    private static final long serialVersionUID = 1L;
    volatile private boolean finished = false;
    private SwingWorker<? extends Object, ? extends Object> task;

    public WaitDialog(Frame owner, String message, SwingWorker<? extends Object, ? extends Object> worker, int startProgress, int doneProgress) {
        super(owner, true);
        assert worker != null;
        task = worker;
        setLayout(new BoxLayout(getContentPane(), BoxLayout.Y_AXIS));
        JLabel label = new JLabel(message);
        add(label);
        final JProgressBar pb;
        if (startProgress < doneProgress) {
            pb = new JProgressBar(startProgress, doneProgress);
        } else {
            pb = new JProgressBar();
            pb.setIndeterminate(true);
        }
        add(pb);
        pack();
        this.setResizable(false);
        this.setDefaultCloseOperation(DO_NOTHING_ON_CLOSE);
        this.setLocationRelativeTo(owner);

        worker.addPropertyChangeListener(new PropertyChangeListener() {

            @Override
            public void propertyChange(PropertyChangeEvent event) {
                if ("state".equals(event.getPropertyName()) && SwingWorker.StateValue.DONE == event.getNewValue()) {
                    finished = true;
                    WaitDialog.this.setVisible(false);
                    WaitDialog.this.dispose();
                }
                if ("progress".equals(event.getPropertyName())) {
                    pb.setValue((Integer) event.getNewValue());
                }

            }
        });
        worker.addPropertyChangeListener(new PropertyChangeListener() {
            @Override
            public void propertyChange(PropertyChangeEvent evt) {
            }
        });

    }

    /**
     * Methode zeigt ProgressBar und blokiert solange Worker sein Task nicht
     * beendet hat
     */
    public void start() {
        task.execute();
        if (!finished) {
            setVisible(true);
        }
    }
}
