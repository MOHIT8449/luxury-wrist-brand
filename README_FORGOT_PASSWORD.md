# LWB — Forgot password (email code)

Login page -> **Forgot password?**

1. User types the **Login Email** (Manage Users). Supabase sends a code to it (6-10 digits, per the project's OTP length).
2. User types the code + new password (twice) -> **Save New Password**. Only the email code is needed.
3. The page goes back to Sign In; the user signs in with the new password and the normal OTP.

Mobile-only logins (no Login Email) cannot use this: Admin types a **New Password** in Manage Users.
SQL: [`lwb_password_reset_setup.sql`](./lwb_password_reset_setup.sql) (`lwb_reset_own_password`) saves the password; it runs by itself when the PR is merged. Supabase's own `updateUser` would ask for the Authenticator code first, so it is not used.

## Setup in Supabase (one time)

### 1. Your own email sender (SMTP) — required

Supabase's built-in email only sends to the project's team members and about 2 emails per hour,
so staff would not get the code.

Supabase -> Authentication -> Emails -> **SMTP Settings** -> Enable custom SMTP. Free options:

| Sender | Free limit | Host / Port | User / Password |
|---|---|---|---|
| Gmail (simplest) | ~500 / day | `smtp.gmail.com` / `465` | Gmail address / **App password** (Google Account -> Security -> 2-Step Verification -> App passwords) |
| Brevo | 300 / day | `smtp-relay.brevo.com` / `587` | Brevo SMTP login / SMTP key |

Sender name: `LWB ERP`. Then Authentication -> Rate Limits: raise "Emails sent per hour" (e.g. 30).

### 2. Reset Password email template — show the code

Authentication -> Emails -> Templates -> **Reset Password**:

- Subject: `LWB ERP password reset code`
- Body:

```html
<h2>LWB ERP</h2>
<p>Your password reset code is:</p>
<p style="font-size:28px;font-weight:bold;letter-spacing:6px">{{ .Token }}</p>
<p>Valid for 1 hour. If you did not ask for this, ignore this email.</p>
```

(`{{ .Token }}` is the code. Do not use the link; the login page asks for the code.)

### 3. Test

Logout -> Forgot password -> type a real Login Email -> check inbox / Spam -> type code + new password.

## Notes

- Cost: free (only the SMTP provider's free limit).
- A wrong email shows the same "code sent" message, so nobody can check which emails exist.
- Resend after 60 seconds (Supabase limit). The code works once, for 1 hour.
