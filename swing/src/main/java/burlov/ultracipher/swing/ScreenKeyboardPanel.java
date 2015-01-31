package burlov.ultracipher.swing;

import java.awt.BorderLayout;
import java.awt.GridLayout;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.util.ArrayList;
import java.util.List;

import javax.swing.BorderFactory;
import javax.swing.JButton;
import javax.swing.JCheckBox;
import javax.swing.JPanel;
import javax.swing.border.EtchedBorder;

public class ScreenKeyboardPanel extends JPanel {
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    public boolean shift = false;
    JPanel jPanel1 = new JPanel();
    JPanel jPanel2 = new JPanel();
    JButton jButton1 = new JButton();
    JButton jButton2 = new JButton();
    JButton jButton9 = new JButton();
    JButton jButton13 = new JButton();
    JButton jButton17 = new JButton();
    JButton jButton21 = new JButton();
    JButton jButton25 = new JButton();
    JButton jButton34 = new JButton();
    JButton jButton47 = new JButton();
    JButton jButton50 = new JButton();
    JButton jButton49 = new JButton();
    JButton jButton48 = new JButton();
    JButton jButton42 = new JButton();
    JButton jButton46 = new JButton();
    JButton jButton45 = new JButton();
    JButton jButton44 = new JButton();
    JButton jButton43 = new JButton();
    JButton jButton41 = new JButton();
    JButton jButton38 = new JButton();
    JButton jButton39 = new JButton();
    JButton jButton40 = new JButton();
    JButton jButton36 = new JButton();
    JButton jButton37 = new JButton();
    JButton jButton29 = new JButton();
    JButton jButton35 = new JButton();
    JButton jButton33 = new JButton();
    JButton jButton32 = new JButton();
    JButton jButton31 = new JButton();
    JButton jButton30 = new JButton();
    JButton jButton28 = new JButton();
    JButton jButton20 = new JButton();
    JButton jButton27 = new JButton();
    JButton jButton26 = new JButton();
    JButton jButton24 = new JButton();
    JButton jButton23 = new JButton();
    JButton jButton22 = new JButton();
    JButton jButton19 = new JButton();
    JButton jButton18 = new JButton();
    JButton jButton16 = new JButton();
    JButton jButton15 = new JButton();
    JButton jButton10 = new JButton();
    JButton jButton12 = new JButton();
    JButton jButton11 = new JButton();
    JButton jButton8 = new JButton();
    JButton jButton7 = new JButton();
    JButton jButton6 = new JButton();
    JButton jButton5 = new JButton();
    JButton jButton4 = new JButton();
    JButton jButton14 = new JButton();
    JButton jButton3 = new JButton();
    GridLayout gridLayout2 = new GridLayout();
    BorderLayout borderLayout1 = new BorderLayout();
    JCheckBox ckCaps = new JCheckBox();
    BorderLayout borderLayout2 = new BorderLayout();
    private List<ActionListener> listeners = new ArrayList<ActionListener>();

    public ScreenKeyboardPanel() {
        try {
            jbInit();
        } catch (Exception e) {
            e.printStackTrace();
        }

    }

    public void addActionListener(ActionListener listener) {
        listeners.add(listener);
    }

    private void buttonPressed(String letter) {
        ActionEvent event = new ActionEvent(this, ActionEvent.ACTION_PERFORMED, letter);
        for (ActionListener listener : listeners) {
            listener.actionPerformed(event);
        }
    }

    private void jbInit() throws Exception {
        this.setLayout(borderLayout1);
        this.setBorder(BorderFactory.createEtchedBorder(EtchedBorder.RAISED));
        jPanel1.setBorder(BorderFactory.createEtchedBorder(EtchedBorder.LOWERED));
        jPanel1.setLayout(gridLayout2);
        jPanel2.setLayout(borderLayout2);
        jButton1.setActionCommand("1");
        jButton1.setText("1 !");
        jButton1.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "!";
                else
                    letter = "1";
                buttonPressed(letter);
            }
        });
        jButton2.setActionCommand("2");
        jButton2.setText("2 \"");
        jButton2.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "\"";
                else
                    letter = "2";
                buttonPressed(letter);
            }
        });
        jButton9.setActionCommand("3");
        jButton9.setText("3 #");
        jButton9.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "#";
                else
                    letter = "3";
                buttonPressed(letter);
            }
        });
        jButton13.setText("4 $");
        jButton13.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "$";
                else
                    letter = "4";
                buttonPressed(letter);
            }
        });
        jButton17.setText("5 %");
        jButton17.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "%";
                else
                    letter = "5";
                buttonPressed(letter);
            }
        });
        jButton21.setText("6 &");
        jButton21.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "&";
                else
                    letter = "6";
                buttonPressed(letter);
            }
        });
        jButton25.setText("7 @");
        jButton25.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "@";
                else
                    letter = "7";
                buttonPressed(letter);
            }
        });
        jButton34.setText("8 (");
        jButton34.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "(";
                else
                    letter = "8";
                buttonPressed(letter);
            }
        });
        jButton47.setText("9 )");
        jButton47.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = ")";
                else
                    letter = "9";
                buttonPressed(letter);
            }
        });
        jButton50.setText("0 =");
        jButton50.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "=";
                else
                    letter = "0";
                buttonPressed(letter);
            }
        });
        jButton49.setText("A");
        jButton49.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "A";
                else
                    letter = "a";
                buttonPressed(letter);
            }
        });
        jButton48.setText("B");
        jButton48.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "B";
                else
                    letter = "b";
                buttonPressed(letter);
            }
        });
        jButton42.setText("C");
        jButton42.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "C";
                else
                    letter = "c";
                buttonPressed(letter);
            }
        });
        jButton46.setText("D");
        jButton46.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "D";
                else
                    letter = "d";
                buttonPressed(letter);
            }
        });
        jButton45.setText("E");
        jButton45.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "E";
                else
                    letter = "e";
                buttonPressed(letter);
            }
        });
        jButton44.setText("F");
        jButton44.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "F";
                else
                    letter = "f";
                buttonPressed(letter);
            }
        });
        jButton43.setText("G");
        jButton43.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "G";
                else
                    letter = "g";
                buttonPressed(letter);
            }
        });
        jButton41.setText("H");
        jButton41.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "H";
                else
                    letter = "h";
                buttonPressed(letter);
            }
        });
        jButton38.setText("I");
        jButton38.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "I";
                else
                    letter = "i";
                buttonPressed(letter);
            }
        });
        jButton39.setText("J");
        jButton39.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "J";
                else
                    letter = "j";
                buttonPressed(letter);
            }
        });
        jButton40.setText("K");
        jButton40.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "K";
                else
                    letter = "k";
                buttonPressed(letter);
            }
        });
        jButton36.setText("L");
        jButton36.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "L";
                else
                    letter = "l";
                buttonPressed(letter);
            }
        });
        jButton37.setText("M");
        jButton37.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "M";
                else
                    letter = "m";
                buttonPressed(letter);
            }
        });
        jButton29.setText("N");
        jButton29.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "N";
                else
                    letter = "n";
                buttonPressed(letter);
            }
        });
        jButton35.setText("O");
        jButton35.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "O";
                else
                    letter = "o";
                buttonPressed(letter);
            }
        });
        jButton33.setText("P");
        jButton33.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "P";
                else
                    letter = "p";
                buttonPressed(letter);
            }
        });
        jButton32.setText("Q");
        jButton32.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "Q";
                else
                    letter = "q";
                buttonPressed(letter);
            }
        });
        jButton31.setText("R");
        jButton31.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "R";
                else
                    letter = "r";
                buttonPressed(letter);
            }
        });
        jButton30.setText("S");
        jButton30.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "S";
                else
                    letter = "s";
                buttonPressed(letter);
            }
        });
        jButton28.setText("T");
        jButton28.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "T";
                else
                    letter = "t";
                buttonPressed(letter);
            }
        });
        jButton20.setText("U");
        jButton20.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "U";
                else
                    letter = "u";
                buttonPressed(letter);
            }
        });
        jButton27.setText("V");
        jButton27.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "V";
                else
                    letter = "v";
                buttonPressed(letter);
            }
        });
        jButton26.setText("W");
        jButton26.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "W";
                else
                    letter = "w";
                buttonPressed(letter);
            }
        });
        jButton24.setText("X");
        jButton24.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "X";
                else
                    letter = "x";
                buttonPressed(letter);
            }
        });
        jButton23.setText("Y");
        jButton23.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "Y";
                else
                    letter = "y";
                buttonPressed(letter);
            }
        });
        jButton22.setText("Z");
        jButton22.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "Z";
                else
                    letter = "z";
                buttonPressed(letter);
            }
        });
        jButton19.setText(", ;");
        jButton19.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = ";";
                else
                    letter = ",";
                buttonPressed(letter);
            }
        });
        jButton18.setText(". :");
        jButton18.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = ":";
                else
                    letter = ".";
                buttonPressed(letter);
            }
        });
        jButton16.setText("< >");
        jButton16.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = ">";
                else
                    letter = "<";
                buttonPressed(letter);
            }
        });
        jButton15.setText("? #");
        jButton15.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "#";
                else
                    letter = "?";
                buttonPressed(letter);
            }
        });
        jButton10.setActionCommand("Space");
        jButton10.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = " ";
                else
                    letter = " ";

                buttonPressed(letter);
            }
        });
        jButton12.setText("{ }");
        jButton12.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "}";
                else
                    letter = "{";
                buttonPressed(letter);
            }
        });
        jButton11.setText("[]");
        jButton11.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "]";
                else
                    letter = "[";
                buttonPressed(letter);
            }
        });
        jButton8.setText("+ -");
        jButton8.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "-";
                else
                    letter = "+";

                buttonPressed(letter);
            }
        });
        jButton7.setActionCommand("Space");
        jButton7.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = " ";
                else
                    letter = " ";

                buttonPressed(letter);
            }
        });
        jButton6.setActionCommand("Space");
        jButton6.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = " ";
                else
                    letter = " ";

                buttonPressed(letter);
            }
        });
        jButton5.setText("* ~");
        jButton5.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "~";
                else
                    letter = "*";

                buttonPressed(letter);
            }
        });
        jButton4.setText("| \'");
        jButton4.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "\'";
                else
                    letter = "|";

                buttonPressed(letter);
            }
        });
        jButton14.setText("/ \\");
        jButton14.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = "\\";
                else
                    letter = "/";

                buttonPressed(letter);
            }
        });
        jButton3.setActionCommand("Space");
        jButton3.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                String letter;
                if (shift)
                    letter = " ";
                else
                    letter = " ";

                buttonPressed(letter);
            }
        });
        gridLayout2.setColumns(10);
        gridLayout2.setRows(5);
        ckCaps.setText("Caps Lock");
        ckCaps.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                shift = ckCaps.isSelected();
            }
        });
        jPanel1.add(jButton1, null);
        jPanel1.add(jButton2, null);
        jPanel1.add(jButton9, null);
        jPanel1.add(jButton13, null);
        jPanel1.add(jButton17, null);
        jPanel1.add(jButton21, null);
        jPanel1.add(jButton25, null);
        jPanel1.add(jButton34, null);
        jPanel1.add(jButton47, null);
        jPanel1.add(jButton50, null);
        jPanel1.add(jButton49, null);
        jPanel1.add(jButton48, null);
        jPanel1.add(jButton42, null);
        jPanel1.add(jButton46, null);
        jPanel1.add(jButton45, null);
        jPanel1.add(jButton44, null);
        jPanel1.add(jButton43, null);
        jPanel1.add(jButton41, null);
        jPanel1.add(jButton38, null);
        jPanel1.add(jButton39, null);
        jPanel1.add(jButton40, null);
        jPanel1.add(jButton36, null);
        jPanel1.add(jButton37, null);
        jPanel1.add(jButton29, null);
        jPanel1.add(jButton35, null);
        jPanel1.add(jButton33, null);
        jPanel1.add(jButton32, null);
        jPanel1.add(jButton31, null);
        jPanel1.add(jButton30, null);
        jPanel1.add(jButton28, null);
        jPanel1.add(jButton20, null);
        jPanel1.add(jButton27, null);
        jPanel1.add(jButton26, null);
        jPanel1.add(jButton24, null);
        jPanel1.add(jButton23, null);
        jPanel1.add(jButton22, null);
        jPanel1.add(jButton19, null);
        jPanel1.add(jButton18, null);
        jPanel1.add(jButton16, null);
        jPanel1.add(jButton15, null);
        jPanel1.add(jButton12, null);
        jPanel1.add(jButton11, null);
        jPanel1.add(jButton8, null);
        jPanel1.add(jButton10, null);
        jPanel1.add(jButton7, null);
        jPanel1.add(jButton6, null);
        jPanel1.add(jButton3, null);
        jPanel1.add(jButton5, null);
        jPanel1.add(jButton4, null);
        jPanel1.add(jButton14, null);
        this.add(jPanel1, BorderLayout.CENTER);
        jPanel2.add(ckCaps, BorderLayout.EAST);
        this.add(jPanel2, BorderLayout.NORTH);
    }

}