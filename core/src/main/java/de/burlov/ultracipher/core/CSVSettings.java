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

import au.com.bytecode.opencsv.CSVWriter;

public class CSVSettings {
    private int nameColumn = 0;
    private int tagsColumn = 1;
    private int dataColumn = 2;
    private char separator = CSVWriter.DEFAULT_SEPARATOR;
    private char quoteChar = CSVWriter.DEFAULT_QUOTE_CHARACTER;
    private char escapeChar = CSVWriter.DEFAULT_ESCAPE_CHARACTER;
    private String lineEnd = CSVWriter.DEFAULT_LINE_END;

    public CSVSettings() {
        super();
    }

    public int getNameColumn() {
        return nameColumn;
    }

    public void setNameColumn(int nameColumn) {
        this.nameColumn = nameColumn;
    }

    public int getTagsColumn() {
        return tagsColumn;
    }

    public void setTagsColumn(int tagsColumn) {
        this.tagsColumn = tagsColumn;
    }

    public int getDataColumn() {
        return dataColumn;
    }

    public void setDataColumn(int dataColumn) {
        this.dataColumn = dataColumn;
    }

    public char getSeparator() {
        return separator;
    }

    public void setSeparator(char separator) {
        this.separator = separator;
    }

    public char getQuoteChar() {
        return quoteChar;
    }

    public void setQuoteChar(char quoteChar) {
        this.quoteChar = quoteChar;
    }

    public char getEscapeChar() {
        return escapeChar;
    }

    public void setEscapeChar(char escapeChar) {
        this.escapeChar = escapeChar;
    }

    public String getLineEnd() {
        return lineEnd;
    }

    public void setLineEnd(String lineEnd) {
        this.lineEnd = lineEnd;
    }

}
