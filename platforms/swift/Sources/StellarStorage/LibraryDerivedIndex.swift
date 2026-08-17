import GRDB
import StellarCore

extension LibraryStore {
  /// Atomically rebuilds disposable search documents from durable library-domain records.
  @discardableResult
  public func rebuildSearchDocuments() async throws -> Int {
    let now = clock.nowMilliseconds()
    do {
      return try await database.write { database in
        try database.execute(sql: "DELETE FROM search_document")
        try database.execute(
          sql: """
            INSERT INTO search_document(
              entity_id, title, aliases, people, genres, romanized, updated_at_ms
            )
            SELECT e.id,
                   COALESCE(
                     (
                       SELECT lm.title
                       FROM localized_metadata lm
                       WHERE lm.entity_id = e.id
                       ORDER BY CASE WHEN lm.locale = 'und' THEN 0 ELSE 1 END, lm.locale
                       LIMIT 1
                     ),
                     e.canonical_title
                   ),
                   trim(
                     COALESCE(e.original_title, '') || ' ' ||
                     COALESCE(
                       (
                         SELECT group_concat(value, ' ')
                         FROM (
                           SELECT lm.title AS value
                           FROM localized_metadata lm
                           WHERE lm.entity_id = e.id
                           ORDER BY lm.locale, lm.title
                         )
                       ),
                       ''
                     )
                   ),
                   COALESCE(
                     (
                       SELECT group_concat(value, ' ')
                       FROM (
                         SELECT p.display_name AS value
                         FROM credit c
                         JOIN person p ON p.id = c.person_id
                         WHERE c.entity_id = e.id
                         ORDER BY c.position, p.display_name, p.uid
                       )
                     ),
                     ''
                   ),
                   COALESCE(
                     (
                       SELECT group_concat(value, ' ')
                       FROM (
                         SELECT gn.name AS value
                         FROM entity_genre eg
                         JOIN genre_name gn ON gn.genre_id = eg.genre_id
                         WHERE eg.entity_id = e.id
                         ORDER BY eg.position,
                                  CASE WHEN gn.locale = 'und' THEN 0 ELSE 1 END,
                                  gn.locale,
                                  gn.name
                       )
                     ),
                     ''
                   ),
                   COALESCE(e.sort_title, ''),
                   ?
            FROM media_entity e
            WHERE e.deleted_at_ms IS NULL AND e.status != 'deleted'
            ORDER BY e.id
            """,
          arguments: [now]
        )
        return database.changesCount
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "search document rebuild failed")
    }
  }
}
