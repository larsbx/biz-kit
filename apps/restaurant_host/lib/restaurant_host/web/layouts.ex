defmodule RestaurantHost.Web.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>{assigns[:page_title] || "Order"}</title>
        <style>
          body { font-family: system-ui, sans-serif; margin: 0 auto; max-width: 48rem; padding: 1rem; }
          .row { display: flex; justify-content: space-between; gap: 1rem; padding: .5rem 0; border-bottom: 1px solid #ddd; }
          button { font: inherit; padding: .4rem .8rem; }
          .order { border: 1px solid #ccc; border-radius: .5rem; padding: .75rem; margin: .75rem 0; }
          button + button { margin-left: .5rem; }
        </style>
        <script src="/assets/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view.min.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrf = document.querySelector("meta[name='csrf-token']").content;
            new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrf}}).connect();
          });
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
