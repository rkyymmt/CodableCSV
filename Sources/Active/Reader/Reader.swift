import Foundation
/// Reads CSV text data row-by-row.
///
/// The `CSVReader` is a sequential reader. It reads each line only once (i.e. it cannot re-read a previous CSV row).
public final class CSVReader: IteratorProtocol, Sequence {
    /// Recipe detailing how to parse the CSV data (i.e. delimiters, date strategy, etc.).
    public let configuration: Configuration
    /// Internal reader settings extracted from the public `configuration` and other values inferred during initialization.
    private let settings: Settings
    /// The header row for the given CSV.
    ///
    /// If empty, the file contained no headers.
    private(set) public var headers: [String]
    /// Lookup dictionary providing fast index discovery for header names.
    private(set) internal var headerLookup: [Int:Int]?
    /// Unicode scalar buffer to keep scalars that hasn't yet been analysed.
    private let buffer: ScalarBuffer
    /// The unicode scalar iterator providing all input data.
    private let iterator: ScalarIterator
    /// Check whether the given unicode scalar is part of the field delimiter sequence.
    private let isFieldDelimiter: DelimiterChecker
    /// Check whether the given unicode scalar is par of the row delimiter sequence.
    private let isRowDelimiter: DelimiterChecker
    /// The amount of rows (counting the header row) that have been read and the amount of fields that should be in each row.
    internal private(set) var count: (rows: Int, fields: Int)
    /// The reader status indicating whether there are remaning lines to read, the CSV has been completely parsed, or an error occurred and no further operation shall be performed.
    public private(set) var status: Status
    /// Index of the row to be parsed next (i.e. a row not yet parsed).
    ///
    /// This index is NOT offseted by the existance of a header row. In other words:
    /// - If a CSV file has a header, the first row after a header (i.e. the first actual data row) will be the integer zero.
    /// - If a CSV file doesn't have a header, the first row to parse will also be zero.
    public var rowIndex: Int { let r = self.count.rows; return self.headers.isEmpty ? r : r - 1 }
    
    /// Creates a reader instance that will be used to parse the given `String`.
    /// - parameter string: A `String` containing CSV formatted data.
    /// - parameter configuration: Recipe detailing how to parse the CSV data (i.e. encoding, delimiters, etc.).
    /// - throws: `CSVError<CSVReader>` exclusively.
    public convenience init(string: String, configuration: Configuration = .init()) throws {
        let buffer = ScalarBuffer(reservingCapacity: 8)
        let iterator = ScalarIterator(scalarIterator: string.unicodeScalars.makeIterator())
        try self.init(configuration: configuration, buffer: buffer, iterator: iterator)
    }
    
    /// Creates a reader instance that will be used to parse the given data blob.
    ///
    /// If the configuration's encoding hasn't been set and the input data doesn't contain a Byte Order Marker (BOM), UTF8 is presumed.
    /// - parameter data: A data blob containing CSV formatted data.
    /// - parameter configuration: Recipe detailing how to parse the CSV data (i.e. encoding, delimiters, etc.).
    /// - throws: `CSVError<CSVReader>` exclusively.
    public convenience init(data: Data, configuration: Configuration = .init()) throws {
        if configuration.presample, let dataEncoding = configuration.encoding {
            // A. If the `presample` configuration has been set and the user has explicitly mark an encoding, then the data can parsed into a string.
            guard let string = String(data: data, encoding: dataEncoding) else { throw Error.mismatched(encoding: dataEncoding) }
            try self.init(string: string, configuration: configuration)
        } else {
            // B. Otherwise, start parsing byte-by-byte.
            let buffer = ScalarBuffer(reservingCapacity: 8)
            // B.1. Check whether the input data has a BOM.
            var dataIterator = data.makeIterator()
            let (inferredEncoding, unusedBytes) = String.Encoding.infer(from: &dataIterator)
            // B.2. Select the appropriate encoding depending from the user provided encoding (if any), and the BOM encoding (if any).
            let encoding = try String.Encoding.selectFrom(provided: configuration.encoding, inferred: inferredEncoding)
            // B.3. Create the scalar iterator producing all `Unicode.Scalar`s from the data bytes.
            let iterator = try ScalarIterator(iterator: dataIterator, encoding: encoding, firstBytes: unusedBytes)
            try self.init(configuration: configuration, buffer: buffer, iterator: iterator)
        }
    }
    
    /// Creates a reader instance that will be used to parse the given CSV file.
    ///
    /// If the configuration's encoding hasn't been set and the input data doesn't contain a Byte Order Marker (BOM), UTF8 is presumed.
    /// - parameter fileURL: The URL indicating the location of the file to be parsed.
    /// - parameter configuration: Recipe detailing how to parse the CSV data (i.e. encoding, delimiters, etc.).
    /// - throws: `CSVError<CSVReader>` exclusively.
    public convenience init(fileURL: URL, configuration: Configuration = .init()) throws {
        if configuration.presample {
            // A. If the `presample` configuration has been set, the file can be completely load into memory.
            try self.init(data: try Data(contentsOf: fileURL), configuration: configuration); return
        } else {
            // B. Otherwise, create an input stream and start parsing byte-by-byte.
            guard let stream = InputStream(url: fileURL) else { throw Error.invalidFile(url: fileURL) }
            // B.1. Open the stream for usage.
            assert(stream.streamStatus == .notOpen)
            stream.open()
            
            let (encoding, unusedBytes): (String.Encoding, [UInt8])
            do {
                // B.2. Check whether the input data has a BOM.
                let inferred = try String.Encoding.infer(from: stream)
                // B.3. Select the appropriate encoding depending from the user provided encoding (if any), and the BOM encoding (if any).
                encoding = try String.Encoding.selectFrom(provided: configuration.encoding, inferred: inferred.encoding)
                unusedBytes = inferred.unusedBytes
            } catch let error {
                if stream.streamStatus != .closed { stream.close() }
                throw error
            }
            
            // B.5. Create the scalar buffer & iterator producing all `Unicode.Scalar`s from the data bytes.
            let buffer = ScalarBuffer(reservingCapacity: 8)
            let iterator = try ScalarIterator(stream: stream, encoding: encoding, chunk: 1024, firstBytes: unusedBytes)
            try self.init(configuration: configuration, buffer: buffer, iterator: iterator)
        }
    }

    /// Designated initializer for the CSV reader.
    /// - parameter configuration: Recipe detailing how to parse the CSV data (i.e. encoding, delimiters, etc.).
    /// - parameter buffer: A buffer storing in-flight `Unicode.Scalar`s.
    /// - parameter iterator: An iterator providing the CSV `Unicode.Scalar`s.
    /// - throws: `CSVError<CSVReader>` exclusively.
    private init(configuration: Configuration, buffer: ScalarBuffer, iterator: ScalarIterator) throws {
        self.configuration = configuration
        self.settings = try Settings(configuration: configuration, iterator: iterator, buffer: buffer)
        (self.headers, self.headerLookup) = (.init(), nil)
        self.buffer = buffer
        self.iterator = iterator
        self.isFieldDelimiter = CSVReader.makeMatcher(delimiter: self.settings.delimiters.field, buffer: self.buffer, iterator: self.iterator)
        self.isRowDelimiter = CSVReader.makeMatcher(delimiter: self.settings.delimiters.row, buffer: self.buffer, iterator: self.iterator)
        self.count = (0, 0)
        self.status = .reading
        
        switch configuration.headerStrategy {
        case .none: break
        case .firstLine:
            guard let headers = try self.parseLine(rowIndex: 0) else { self.status = .finished; return }
            guard !headers.isEmpty else { throw Error.invalidEmptyHeader() }
            self.headers = headers
            self.count = (rows: 1, fields: headers.count)
//        case .unknown:
//            #warning("TODO")
        }
    }
}

extension CSVReader {
    /// Advances to the next row and returns it, or `nil` if no next row exists.
    /// - warning: If the CSV file being parsed contains invalid characters, this function will crash. For safer parsing use `parseRow()`.
    /// - seealso: parseRow()
    @inlinable public func next() -> [String]? {
        return try! self.parseRow()
    }
    
    /// Parses a CSV row and wraps it in a convenience structure giving accesses to fields through header titles/names.
    ///
    /// Since CSV parsing is sequential, if a previous call of this function encountered an error, subsequent calls will throw the same error.
    /// - throws: `CSVError<CSVReader>` exclusively.
    /// - returns: A record structure or `nil` if there isn't anything else to parse. If a record is returned there shall always be at least one field.
    /// - seealso: parseRow()
    public func parseRecord() throws -> Record? {
        guard let row = try self.parseRow() else { return nil }
        
        let lookup: [Int:Int]
        if let l = self.headerLookup {
            lookup = l
        } else {
            lookup = try self.makeHeaderLookup()
            self.headerLookup = lookup
        }
        
        return .init(row: row, lookup: lookup)
    }
    
    /// Parses a CSV row.
    ///
    /// Since CSV parsing is sequential, if a previous call of this function encountered an error, subsequent calls will throw the same error.
    /// - throws: `CSVError<CSVReader>` exclusively.
    /// - returns: The row's fields or `nil` if there isn't anything else to parse. The row will never be an empty array.
    public func parseRow() throws -> [String]? {
        switch self.status {
        case .reading: break
        case .finished: return nil
        case .failed(let e): throw e
        }
        
        let result: [String]?
        do {
            result = try self.parseLine(rowIndex: self.count.rows)
        } catch let error {
            let e = error as! CSVError<CSVReader>
            self.status = .failed(e)
            throw e
        }
        
        guard let numFields = result?.count else {
            self.status = .finished
            return nil
        }
        
        if self.count.rows > 0 {
            guard self.count.fields == numFields else { throw Error.invalidFieldCount(rowIndex: self.count.rows+1, parsed: numFields, expected: self.count.fields) }
        } else {
            self.count.fields = numFields
        }
        
        self.count.rows += 1
        return result
    }
}

extension CSVReader {
    /// Creates the lookup dictionary from the headers row.
    internal func makeHeaderLookup() throws -> [Int:Int] {
        var result: [Int:Int] = .init(minimumCapacity: self.headers.count)
        for (index, header) in self.headers.enumerated() {
            let hash = header.hashValue
            guard case .none = result.updateValue(index, forKey: hash) else {
                throw Error.invalidHashableHeader()
            }
        }
        return result
    }
    
    /// Parses a CSV row.
    /// - throws: `CSVError<CSVReader>` exclusively.
    /// - returns: The row's fields or `nil` if there isn't anything else to parse. The row will never be an empty array.
    private func parseLine(rowIndex: Int) throws -> [String]? {
        var result: [String] = []

        // 1. This loops starts a row, and then continue for every field.
        loop: while true {
            // 2. Try to retrieve a scalar (if there is none, we reached the EOF).
            guard let scalar = try self.buffer.next() ?? self.iterator.next() else {
                switch result.isEmpty {
                // 2.A. If no fields has been parsed, return nil.
                case true: return nil
                // 2.B. If there were previous fields, the EOF counts as en empty field (since there was no row delimiter previously).
                case false: result.append(""); break loop
                }
            }
            
            // 3. Check for characters to trim before a field is parsed.
            if !self.settings.trimCharacters.isEmpty, self.settings.trimCharacters.contains(scalar) {
                continue loop
            }
            
            // 4. If the unicode scalar retrieved is a double quote, an escaped field is awaiting for parsing.
            if scalar == self.settings.escapingScalar {
                let field = try self.parseEscapedField(rowIndex: rowIndex)
                result.append(field.value)
                if field.isAtEnd { break loop }
            // 5. If the field delimiter is encountered, an implicit empty field has been defined.
            } else if try self.isFieldDelimiter(scalar) {
                result.append("")
            // 6. If the row delimiter is encountered, an implicit empty field has been defined (for rows that already have content).
            } else if try self.isRowDelimiter(scalar) {
                result.append("")
                break loop
            // 7. If a regular character is encountered, an "unescaped field" is awaiting parsing.
            } else {
                let field = try self.parseUnescapedField(starting: scalar, rowIndex: rowIndex)
                result.append(field.value)
                if field.isAtEnd { break loop }
            }
        }
        
        return result
    }

    /// Parses the awaiting unicode scalars expecting to form a "unescaped field".
    /// - parameter starting: The first regular scalar in the unescaped field.
    /// - parameter rowIndex: The index of the row being parsed.
    /// - throws: `CSVError<CSVReader>` exclusively.
    /// - returns: The parsed field and whether the row/file ending characters have been found.
    private func parseUnescapedField(starting: Unicode.Scalar, rowIndex: Int) throws -> (value: String, isAtEnd: Bool) {
        var field: String.UnicodeScalarView = .init(repeating: starting, count: 1)
        var reachedRowsEnd = false

        fieldLoop: while true {
            // Try to retrieve an scalar (if not, it is the EOF).
            guard let scalar = try self.buffer.next() ?? self.iterator.next() else { reachedRowsEnd = true; break fieldLoop }
            // There cannot be double quotes on unescaped fields. If one is encountered, an error is thrown.
            if scalar == self.settings.escapingScalar {
                throw Error.invalidUnescapedField(rowIndex: rowIndex)
            // If the field delimiter is encountered, return the already parsed characters.
            } else if try self.isFieldDelimiter(scalar) {
                reachedRowsEnd = false
                break fieldLoop
            // If the row delimiter is encountered, return the already parsed characters.
            } else if try self.isRowDelimiter(scalar) {
                reachedRowsEnd = true
                break fieldLoop
            // If it is a regular unicode scalar, just store it and continue parsing.
            } else {
                field.append(scalar)
            }
        }
        
        if !self.settings.trimCharacters.isEmpty {
            while let lastScalar = field.last, self.settings.trimCharacters.contains(lastScalar) {
                field.removeLast()
            }
        }

        return (String(field), reachedRowsEnd)
    }

    /// Parses the awaiting unicode scalars expecting to form a "escaped field".
    ///
    /// When this function is executed, the quote opening the "escaped field" has already been read.
    /// - parameter rowIndex: The index of the row being parsed.
    /// - throws: `CSVError<CSVReader>` exclusively.
    /// - returns: The parsed field and whether the row/file ending characters have been found.
    private func parseEscapedField(rowIndex: Int) throws -> (value: String, isAtEnd: Bool) {
        var field: String.UnicodeScalarView = .init()
        var reachedRowsEnd = false

        fieldLoop: while true {
            // 1. Retrieve an scalar (if not there, it means EOF). This case is not allowed without closing the escaping field first.
            guard let scalar = try self.buffer.next() ?? self.iterator.next() else { throw Error.invalidEOF(rowIndex: rowIndex) }
            // 2. If the retrieved scalar is not a quote (i.e. "), just store it and continue parsing.
            guard scalar == self.settings.escapingScalar else { field.append(scalar); continue fieldLoop }
            // 3. If the retrieved scalar was a quote, retrieve the following scalar and check if it is EOF. If so, the field has finished and also the row and the file.
            guard var followingScalar = try self.buffer.next() ?? self.iterator.next() else { reachedRowsEnd = true; break fieldLoop }
            // 4. If the second retrieved scalar is another quote, the data is escaping a single quote scalar (quotes are escaped with other quotes).
            guard followingScalar != self.settings.escapingScalar else { field.append(self.settings.escapingScalar); continue fieldLoop }
            // 5. Once this point is reached, the field has been properly escaped.
            if !self.settings.trimCharacters.isEmpty {
                // 6. Trim any character after the quote if necessary.
                while self.settings.trimCharacters.contains(followingScalar) {
                    guard let tmpScalar = try self.buffer.next() ?? self.iterator.next() else {
                        reachedRowsEnd = true
                        break fieldLoop
                    }
                    followingScalar = tmpScalar
                }
            }
            
            if try self.isFieldDelimiter(followingScalar) {
                break
            } else if try self.isRowDelimiter(followingScalar) {
                reachedRowsEnd = true
                break
            } else {
                throw Error.invalidEscapedField(rowIndex: rowIndex)
            }
        }

        return (String(field), reachedRowsEnd)
    }
}

fileprivate extension CSVReader.Error {
    /// The given `String.Encoding` is not yet supported by the library.
    /// - parameter encoding: The desired byte representatoion.
    static func mismatched(encoding: String.Encoding) -> CSVError<CSVReader> {
        .init(.invalidConfiguration,
              reason: "The data blob didn't match the given string encoding.",
              help: "Let the reader infer the encoding or make sure the data blob is correctly formatted.",
              userInfo: ["Encoding": encoding])
    }
    /// Error raised when an input stream cannot be created to the indicated file URL.
    /// - parameter url: The URL address of the invalid file.
    static func invalidFile(url: URL) -> CSVError<CSVReader> {
        .init(.streamFailure,
              reason: "Creating an input stream to the given file URL failed.",
              help: "Make sure the URL is valid and you are allowed to access the file. Alternatively set the configuration's presample or load the file in a data blob and use the reader's data initializer.",
              userInfo: ["File URL": url])
    }
    /// Error raised when a header was required, but the line was empty.
    static func invalidEmptyHeader() -> CSVError<CSVReader> {
        .init(.invalidConfiguration,
              reason: "A header line was expected, but an empty line was found instead.",
              help: "Make sure there is a header line at the very beginning of the file or mark the configuration as 'no header'.")
    }
    /// Error raised when a record is fetched, but there are header names which has the same hash value (i.e. they have the same name).
    static func invalidHashableHeader() -> CSVError<CSVReader> {
        .init(.invalidInput,
              reason: "The header row contain two fields with the same value.",
              help: "Request a row instead of a record.")
    }
    /// Error raised when the number of fields are not kept constant between CSV rows.
    /// - parameter rowIndex: The location of the row which generated the error.
    /// - parameter parsed: The number of parsed fields.
    /// - parameter expected: The number of fields expected.
    static func invalidFieldCount(rowIndex: Int, parsed: Int, expected: Int) -> CSVError<CSVReader> {
        .init(.invalidInput,
              reason: "The number of fields is not constant between rows.",
              help: "Make sure the CSV file has always the same amount of fields per row.",
              userInfo: ["Row index": rowIndex,
                         "Number of parsed fields": parsed,
                         "Number of expected fields": expected])
    }
    /// Error raised when a unescape field finds a unescape quote within it.
    /// - parameter rowIndex: The location of the row which generated the error.
    static func invalidUnescapedField(rowIndex: Int) -> CSVError<CSVReader> {
        .init(.invalidInput,
              reason: "Quotes aren't allowed within fields which don't start with quotes.",
              help: "Sandwich the targeted field with quotes and escape the quote within the field.",
              userInfo: ["Row index": rowIndex])
    }
    /// Error raised when an EOF has been received but the last CSV field was not finalized.
    /// - parameter rowIndex: The location of the row which generated the error.
    static func invalidEOF(rowIndex: Int) -> CSVError<CSVReader> {
        .init(.invalidInput,
              reason: "The last field is escaped (through quotes) and an EOF (End of File) was encountered before the field was properly closed (with a final quote character).",
              help: "End the targeted field with a quote.",
              userInfo: ["Row index": rowIndex])
    }
    /// Error raised when an escaped field hasn't been properly finalized.
    /// - parameter rowIndex: The location of the row which generated the error.
    static func invalidEscapedField(rowIndex: Int) -> CSVError<CSVReader> {
        .init(.invalidInput,
              reason: "The last field is escaped (through quotes) and an EOF (End of File) was encountered before the field was properly closed (with a final quote character).",
              help: "End the targeted field with a quote.",
              userInfo: ["Row index": rowIndex])
    }
}
