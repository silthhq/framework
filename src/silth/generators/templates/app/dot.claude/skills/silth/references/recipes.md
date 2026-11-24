# Recipes

## Add a column
1. `silth g migration add_slug_to_posts slug:string`
2. Edit the migration if needed (`add_index :posts, :slug, unique: true`).
3. Add `column slug : String?` to the model (nilable until backfilled).
4. `silth db:migrate`, update forms (`f.text_field :slug`) and `params.permit(..., :slug, from: :post)`.

## Add an authenticated area
1. `silth g auth && silth db:migrate` (once).
2. In routes: `scope "/account", name: "account", middleware: [:auth] do … end`.
3. In controllers use `ctx.auth_user.as(User)` (define `current_user` in ApplicationController).

## Add a JSON endpoint with docs
1. `silth g api Invoice number:string total:decimal`.
2. Annotate actions with `@[Silth::API(summary: "…", body: InvoiceRequest, response: Invoice)]`.
3. Check `/docs/api`.

## Background processing
1. `silth g job SendReport`; serialize ids, not models.
2. Dispatch with `SendReportJob.new(user.id).dispatch_after_commit` inside transactions.
3. Production: `config/queue.yml` → `driver: database`; run `bin/cli queue:work`.

## Real-time UI
1. `silth g live Notifications`.
2. Declare `def subscriptions; ["user:#{user.try(&.auth_id)}"]; end`.
3. From anywhere: `Silth::Live.refresh("user:42")`.

## Vector search (RAG)
1. Migration: `enable_extension "vector"`, `t.vector :embedding, 1536`, `t.index :embedding, using: "hnsw", opclass: "vector_cosine_ops"`.
2. Model: `column embedding : Array(Float32)?`.
3. Query: `Document.nearest(:embedding, query_vector).limit(5).to_a`.

## Fix "undefined constant X" at compile time
The class is used before its file is required, or a base class is loaded after its subclass. Check `src/app.cr` require order.

## Fix "Missing prop" / "MissingAttribute"
A non-nilable prop/column was read while nil. Pass it, give it a default, or read with the `?` variant.
