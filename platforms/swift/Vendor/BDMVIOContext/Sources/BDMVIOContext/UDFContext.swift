//
//  UDFContext.swift
//  BDMVIOContext
//
//  Created by kintan on 1/18/25.
//

import FFmpegKit
import Foundation
import KSPlayer
import udfread

struct UDFContext {
    var input: udfread_block_input
    private let download: DownloadProtocol
    private var urlPos = Int64(0)

    init(download: DownloadProtocol) {
        self.download = download
        input = udfread_block_input()
        input.read = { input, lba, buf, nblocks, _ -> Int32 in
            guard let input, let buf else {
                return 0
            }
            let context = input.withMemoryRebound(to: UDFContext.self, capacity: 1) { pointer in
                pointer
            }
            let download = context.pointee.download
            let begin = Int64(lba) * Int64(UDF_BLOCK_SIZE)
            if context.pointee.urlPos != begin {
                download.seek(offset: begin, whence: SEEK_SET)
            }
            let size = download.read(buffer: buf.assumingMemoryBound(to: UInt8.self), size: Int32(nblocks) * Int32(UDF_BLOCK_SIZE))
            if size > 0 {
                context.pointee.urlPos = begin + Int64(size)
            }
            return size / UDF_BLOCK_SIZE
        }
        input.close = { input -> Int32 in
            guard let input else {
                return 0
            }
            let context = input.withMemoryRebound(to: UDFContext.self, capacity: 1) { pointer in
                pointer
            }
            context.pointee.close()
            return 0
        }
    }

    func close() {
        download.close()
    }
}

public final class LocalFileDownload: DownloadProtocol, CustomStringConvertible {
    public let bufferSize: Int32 = 512 * 1024
    private let fd: Int32
    private let size: Int64
    public let description: String
    public convenience init(url: URL) {
        self.init(url: url, name: url.lastPathComponent, size: 0)
    }

    public init(url: URL, name: String, size: Int64) {
        fd = open(url.path, O_RDONLY)
        if size > 0 {
            self.size = size
        } else {
            let pos = lseek(fd, 0, SEEK_END)
            self.size = max(0, pos)
            lseek(fd, 0, SEEK_SET)
        }
        description = name
    }

    public func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        Int32(Darwin.read(fd, buffer, Int(size)))
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        lseek(fd, offset, whence)
    }

    public func close() {
        Darwin.close(fd)
    }

    public func fileSize() -> Int64 {
        size
    }
}

import QuartzCore

public class URLContextCompleteDownload: DownloadProtocol {
    public let bufferSize: Int32
    var context: UnsafeMutablePointer<URLContext>?
    public init(url: URL, formatContextOptions: [String: Any], interrupt: AVIOInterruptCB, bufferSize: Int32 = 512 * 1024) throws {
        self.bufferSize = bufferSize
        var avOptions = formatContextOptions.avOptions
        var interruptCB = interrupt
        let result = ffurl_open_whitelist(&context, url.ffmpegString, AVIO_FLAG_READ, &interruptCB, &avOptions, nil, nil, nil)
        av_dict_free(&avOptions)
        if result != 0 {
            throw KSPlayerError(errorCode: .formatOpenInput, avErrorCode: result)
        }
    }

    public func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let context else {
            return swift_AVERROR_EOF
        }
        // 因为iso的最小片段是2KB，所以一定要read_complete，不然数据不完整，会判断不出是iso
//        if size <= 2 * 1024 {
        return ffurl_read_complete(context, buffer, size)
//        } else {
//            return ffurl_read2(context, buffer, size)
//        }
    }

    private var lastseekTime: CFTimeInterval = 0
    public func seek(offset: Int64, whence: Int32) -> Int64 {
        guard let context else {
            return -1
        }
        let time = CACurrentMediaTime()
        // 115如果seek的间隔太短的话，那会被风控，所以需要暂停一小会儿
        let gap = time - lastseekTime
        if gap < 0.01 {
            Thread.sleep(forTimeInterval: 0.01 - gap)
        }
        let size = ffurl_seek2(context, offset, whence)
        lastseekTime = CACurrentMediaTime()
        return size
    }

    public func fileSize() -> Int64 {
        guard let context else {
            return -1
        }
        return seek(offset: 0, whence: AVSEEK_SIZE)
    }

    public func close() {
        ffurl_closep(&context)
    }
}

public final class URLSessionDownload: DownloadProtocol, CustomStringConvertible, @unchecked Sendable {
    /// 这个不能太大。不然首帧耗时可能会增加。
    public nonisolated(unsafe) static var minRequesetSize = 256 * 1024
    public let description: String
    private let urlSession: URLSession
    private let url: URL
    private var cacheData: Data?
    private var cacheBegin: Int = 0
    // 当前的位置
    private var urlPos = Int64(0)
    private var endSize: Int64
    private var request: URLRequest
    public convenience init(url: URL, userAgent: String?) {
        self.init(url: url, name: url.lastPathComponent, size: 0, userAgent: userAgent)
    }

    public init(url: URL, name: String, size: Int64, userAgent: String?) {
        self.url = url
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        if let userAgent {
            configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        }
        urlSession = URLSession(configuration: configuration, delegate: URLSessionDownloadDelegate(), delegateQueue: nil)
        request = URLRequest(url: url)
        description = name
        endSize = size
    }

    public func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer else {
            return 0
        }
//        KSLog(size)
        let result = read(buffer: buffer, begin: Int(urlPos), end: Int(urlPos) + Int(size))
        if result > 0 {
            urlPos += Int64(result)
        }
        return Int32(result)
    }

    public func read(buffer: UnsafeMutablePointer<UInt8>, begin: Int, end: Int) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0) // 初始信号量值为 0
        nonisolated(unsafe) var size = end - begin
        nonisolated(unsafe) var buffer = buffer
        nonisolated(unsafe) var begin = begin
        nonisolated(unsafe) var end = end
        nonisolated(unsafe) var addSize = 0
        // 尽量复用内存缓存的数据。减少请求次数。
        if let cacheData, begin >= cacheBegin {
            if cacheData.count + cacheBegin >= end {
                cacheData.advanced(by: begin - cacheBegin).copyBytes(to: buffer, count: size)
                return Int32(size)
            } else if begin < cacheData.count + cacheBegin {
                addSize = cacheData.count + cacheBegin - begin
                cacheData.advanced(by: begin - cacheBegin).copyBytes(to: buffer, count: addSize)
                buffer = buffer.advanced(by: addSize)
                size -= addSize
                begin += addSize
                end += addSize
            }
        }
        cacheData = nil
        cacheBegin = 0
        if size < Self.minRequesetSize {
            end = begin + Self.minRequesetSize
        }
//        KSLog("begin=\(begin), end=\(end), size=\(end - begin), addSize=\(addSize), endSize=\(endSize), url=\(url)")
        request.setValue("bytes=\(begin)-\(end - 1)", forHTTPHeaderField: "Range")
        Task { [buffer]
            do {
                let (data, response) = try await urlSession.data(for: request)
                if let response = response as? HTTPURLResponse, let range = response.allHeaderFields["Content-Range"] as? String, let total = range.split(separator: "/").last, let fileSize = Int64(total) {
                    self.endSize = fileSize
                }
                size = min(data.count, size)
                data.copyBytes(to: buffer, count: size)
                if data.count > size {
                    self.cacheData = data.advanced(by: size)
                    self.cacheBegin = begin + size
                }
                semaphore.signal()
            } catch {
                KSLog(error)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return Int32(size + addSize)
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        var whence = whence
        var offset = offset
        if whence == SEEK_CUR {
            whence = SEEK_SET
            offset += urlPos
        } else if whence == SEEK_END {
            whence = SEEK_SET
            offset += fileSize()
        }
        guard whence == SEEK_SET else {
            return -1
        }
        urlPos = offset
        return urlPos
    }

    public func close() {
        cacheData = nil
        urlSession.invalidateAndCancel()
    }

    public func fileSize() -> Int64 {
        endSize
    }

    #if DEBUG
    deinit {
        KSLog("")
    }
    #endif
}

final class URLSessionDownloadDelegate: NSObject, URLSessionDelegate {
    /// 自定义 SSL 证书验证逻辑
    func urlSession(_: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        // 忽略 SSL 证书验证（不推荐在生产环境中使用）
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
