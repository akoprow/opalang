/*
    Copyright © 2011 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA.  If not, see <http://www.gnu.org/licenses/>.
*/
/*
 * Author    : Nicolas Glondu <nicolas.glondu@mlstate.com>
 **/

//package stdlib.apis.github.user
import stdlib.apis.github
import stdlib.apis.github.lib

/**
 * GitHub user API module
 *
 * @category api
 * @author Nicolas Glondu, 2011
 * @destination public
 */

/**
 * Type of a GitHub user provided to [GHUser.show]
 */
type GHUser.t =
    { self  : string } /** Token of user - provides more information */
  / { login : string } /** Login of user */

@private GHUp = {{

  @private GP = GHParse

  one_full_user(res) =
    GP.dewrap_obj(res, "user", GP.get_user)

  multiple_full_users(res) =
    GP.dewrap_list(res, "users", GP.get_user)

  multiple_users_ids(res) =
    GP.multiple_strings(res, "users")

  multiple_emails(res) =
    GP.multiple_strings(res, "emails")

  multiple_public_keys(res) =
    GP.dewrap_list(res, "public_keys", GP.get_public_key)

}}

GHUser = {{

  /* Search and display */

  search(req) =
    path = "/user/search/{req}"
    GHLib.api_get(path, [], GHUp.multiple_full_users)

  show(user:GHUser.t) =
    (path, data) = match user with
      | ~{self} ->
        ("/user/show", [("access_token", self)])
      | ~{login} ->
        ("/user/show/{login}", [])
    GHLib.api_get(path, data, GHUp.one_full_user)

  /* Follow(/ing/ers) */

  get_following(user) =
    path = "/user/show/{user}/following"
    GHLib.api_get(path, [], GHUp.multiple_users_ids)

  get_followers(user) =
    path = "/user/show/{user}/followers"
    GHLib.api_get(path, [], GHUp.multiple_users_ids)

  follow(user, token) =
    path = "/user/follow/{user}"
    GHLib.api_post_logged(path, token, GHUp.multiple_users_ids)

  unfollow(user, token) =
    path = "/user/unfollow/{user}"
    GHLib.api_post_logged(path, token, GHUp.multiple_users_ids)

  /* Public keys */

  get_keys(token) =
    path = "/user/keys"
    GHLib.api_get_logged(path, token, GHUp.multiple_public_keys)

  add_key(title, key, token) =
    path = "/user/key/add"
    data = [("title", title), ("key", key),
            ("access_token", token)]
    GHLib.api_post(path, data, GHUp.multiple_public_keys)

  remove_key(id, token) =
    path = "/user/key/remove"
    data = [("id", id), ("access_token", token)]
    GHLib.api_post(path, data, GHUp.multiple_public_keys)

  /* Emails */

  get_emails(token) =
    path = "/user/emails"
    GHLib.api_get_logged(path, token, GHUp.multiple_emails)

  add_email(email, token) =
    path = "/user/email/add"
    data = [("email", email), ("access_token", token)]
    GHLib.api_post(path, data, GHUp.multiple_emails)

  remove_email(email, token) =
    path = "/user/email/remove"
    data = [("email", email), ("access_token", token)]
    GHLib.api_post(path, data, GHUp.multiple_emails)

  /* Not working API call
   update(updates, token) =
   */

}}
