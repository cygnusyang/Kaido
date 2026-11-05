/**
 * resend.js — 落地页的「已购买？重发授权」。
 *
 * 独立文件而不是内联，是因为英文页与中文页共用同一套逻辑；文案按
 * <html lang> 切换，避免两份代码各自漂移。
 *
 * 后端对「有订单 / 没订单 / 已过期」返回同一句话，这里也不做任何区分性提示——
 * 一旦前端把三种结果渲染成不同文案，防枚举就白做了。
 */
(function () {
  var ENDPOINT = "https://kaido-license-service.cygnusyang.workers.dev/resend";

  var form = document.querySelector("[data-resend-form]");
  if (!form) return;

  var status = form.parentNode.querySelector(".resend-status");
  var input = form.querySelector("input[name=email]");
  var button = form.querySelector("button");
  var zh = /^zh/i.test(document.documentElement.lang || "");

  var copy = {
    sending: zh ? "正在发送…" : "Sending…",
    empty: zh ? "请输入邮箱。" : "Please enter your email.",
    sent: zh
      ? "如果这个邮箱有订单，我们已经重发了授权。请检查收件箱和垃圾邮件文件夹。"
      : "If that email has an order, we've just resent your license. Check your inbox and spam folder.",
    bad: zh ? "邮箱格式不正确，请检查。" : "That doesn't look like a valid email address.",
    limit: zh ? "请求过于频繁，请稍后再试。" : "Too many requests. Please try again in a little while.",
    failed: zh
      ? "发送失败。请稍后重试，或直接回复购买确认邮件联系我们。"
      : "Couldn't send the email. Please try again, or reply to your purchase confirmation."
  };

  function setStatus(text, kind) {
    status.textContent = text;
    status.className = "resend-status" + (kind ? " is-" + kind : "");
  }

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var email = (input.value || "").trim();
    if (!email) {
      setStatus(copy.empty, "error");
      input.focus();
      return;
    }

    button.disabled = true;
    setStatus(copy.sending, "");

    fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email })
    })
      .then(function (res) {
        return res.json().then(
          function (body) { return { status: res.status, body: body }; },
          function () { return { status: res.status, body: null }; }
        );
      })
      .then(function (r) {
        if (r.status === 200) {
          setStatus(copy.sent, "ok");
        } else if (r.status === 400) {
          setStatus(copy.bad, "error");
        } else if (r.status === 429) {
          setStatus(copy.limit, "error");
        } else {
          setStatus(copy.failed, "error");
        }
      })
      .catch(function () {
        setStatus(copy.failed, "error");
      })
      .finally(function () {
        button.disabled = false;
      });
  });
})();
