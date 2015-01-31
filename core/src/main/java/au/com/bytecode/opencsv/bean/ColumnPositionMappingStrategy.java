package au.com.bytecode.opencsv.bean;

import java.io.IOException;

import au.com.bytecode.opencsv.CSVReader;

/**
 * Copyright 2007 Kyle Miller.
 * <p/>
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 * <p/>
 * http://www.apache.org/licenses/LICENSE-2.0
 * <p/>
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */

public class ColumnPositionMappingStrategy extends HeaderColumnNameMappingStrategy {
    protected String[] columnMapping = new String[]{};

    @Override
    public void captureHeader(CSVReader reader) throws IOException {
        // do nothing, first line is not header
    }

    @Override
    protected String getColumnName(int col) {
        return (null != columnMapping && col < columnMapping.length) ? columnMapping[col] : null;
    }

    public String[] getColumnMapping() {
        return columnMapping;
    }

    public void setColumnMapping(String[] columnMapping) {
        this.columnMapping = columnMapping;
    }
}
