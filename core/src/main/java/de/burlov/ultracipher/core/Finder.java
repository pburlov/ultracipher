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
package de.burlov.ultracipher.core;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Findet am besten zu Suchstring passende Eintraege
 * <p/>
 * Created 09.03.2009
 *
 * @author paul
 */
public class Finder {
    /**
     * Looks for entries that matches the given search text.
     *
     * @param searchText
     * @return
     */
    public List<DataEntry> findEntries(String searchText, Collection<DataEntry> entries, int maxResults) {
        Set<String> searchTerms = splitTerms(searchText);
        ArrayList<ScoredEntry> list = new ArrayList<ScoredEntry>(entries.size());
        for (DataEntry entry : entries) {
            int score = scoreEntry(searchTerms, entry);
            if (score > 0) {
                list.add(new ScoredEntry(score, entry));
            }
        }
        Collections.sort(list);
        maxResults = Math.min(maxResults, entries.size());
        List<DataEntry> ret = new ArrayList<DataEntry>(maxResults);
        for (ScoredEntry entry : list) {
            ret.add(entry.entry);
            maxResults--;
            if (maxResults < 1) {
                break;
            }
        }
        return ret;
    }

    private int scoreEntry(Set<String> searchTerms, DataEntry entry) {
        int score = 0;
        Set<String> terms = splitTerms(entry.getName());
        /*
         * Uebereinstimmungen in 'name' doppel so hoch bewerten
		 */
        score += scoreTerms(searchTerms, terms) * 2;
        terms = splitTerms(entry.getTags());
        score += scoreTerms(searchTerms, terms);
        terms = splitTerms(entry.getText());
        score += scoreTerms(searchTerms, terms);
        return score;
    }

    private int scoreTerms(Collection<String> searchTerms, Collection<String> dataTerms) {
        int score = 0;
        for (String term1 : searchTerms) {
            for (String term2 : dataTerms) {
                if (term2.contains(term1)) {
                    score += 1;
                }
                // if (term1.contains(term2))
                // {
                // score++;
                // }
            }
        }
        return score;
    }

    /**
     * String in Terme aufsplitten
     *
     * @param terms
     * @return
     */
    private Set<String> splitTerms(String terms) {
        terms = terms.trim();
        terms = terms.toUpperCase();
        Set<String> ret = new HashSet<String>();
        for (String term : terms.split(" ")) {
            if (term.trim().length() > 0) {
                ret.add(term);
            }
        }
        return ret;

    }

    class ScoredEntry extends DataEntry implements Comparable<ScoredEntry> {
        private int score;
        private DataEntry entry;

        public ScoredEntry(int score, DataEntry entry) {
            super(entry.getId());
            this.score = score;
            this.entry = entry;
        }

        @Override
        public int compareTo(ScoredEntry o) {
            return o.score - score;
        }

        @Override
        public String getName() {
            return entry.getName();
        }

        @Override
        public void setName(String name) {
            entry.setName(name);
        }

        @Override
        public String getTags() {
            return entry.getTags();
        }

        @Override
        public void setTags(String tags) {
            entry.setTags(tags);
        }

        @Override
        public String getText() {
            return entry.getText();
        }

        @Override
        public void setText(String text) {
            entry.setText(text);
        }

        /*
         * (non-Javadoc)
         *
         * @see de.b.op.model.IDataEntry#getLastChangedTime()
         */
        @Override
        public long getLastChanged() {
            return entry.getLastChanged();
        }

    }
}
